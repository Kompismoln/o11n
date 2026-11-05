{ pkgs }:
let
  inherit (pkgs) lib;

  port = 23000;
  folder = "/srv/allotments/user-alice";
  deviceId =
    host:
    lib.trim (
      builtins.readFile ../inventories/allotments/public-keys/host-${host}-syncthing-user-alice.zhost.pub
    );

  # Fact: the inventory's secrets, decrypted, which protect nothing.
  secret = host: owner: {
    environment.etc."allotment-sync.pem" = {
      source = ./allotment-sync/${host}.pem;
      mode = "0400";
    }
    // owner;
  };
in
pkgs.testers.runNixOSTest {
  name = "o11n-allotment-sync";

  imports = [ ./timeout.nix ];
  globalTimeout = 300;

  nodes.zhost =
    { config, ... }:
    {
      imports = [
        ../../nixos/allotment-sync.nix
        (secret "zhost" {
          user = "alice";
          group = "alice";
        })
      ];
      users.users.alice = {
        isSystemUser = true;
        uid = 1000;
        group = "alice";
      };
      users.groups.alice.gid = 1000;
      networking.useNetworkd = true;
      networking.firewall.allowedTCPPorts = [ port ];
      environment.systemPackages = [ pkgs.jq ];
      systemd.tmpfiles.rules = [
        "d ${folder} 0700 1000 1000 - -"
        "d /var/lib/allotment-sync 0755 root root - -"
        "d /var/lib/allotment-sync/user-alice.zhost 0700 1000 1000 - -"
      ];
      o11n.allotment-sync."user-alice.zhost" = {
        inherit folder;
        state = "/var/lib/allotment-sync/user-alice.zhost";
        user = "alice";
        group = "alice";
        secret = "/etc/allotment-sync.pem";
        listen = [ "tcp://${config.networking.primaryIPAddress}:${toString port}" ];
        wants = [ "systemd-networkd-wait-online@eth1.service" ];
        self = {
          id = deviceId "zhost";
          name = "zhost";
        };
        peers = [
          {
            id = deviceId "laptop";
            name = "laptop";
          }
        ];
      };
    };

  nodes.laptop =
    { nodes, ... }:
    {
      imports = [
        ../../nixos/allotment-sync.nix
        (secret "laptop" {
          user = "alice";
          group = "alice";
        })
      ];
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        group = "alice";
      };
      users.groups.alice.gid = 1000;
      o11n.allotment-sync."user-alice.zhost" = {
        folder = "/home/alice/.o11n/allotments/zhost";
        state = "/home/alice/.o11n/syncthing/zhost";
        user = "alice";
        group = "alice";
        secret = "/etc/allotment-sync.pem";
        self = {
          id = deviceId "laptop";
          name = "laptop";
        };
        peers = [
          {
            id = deviceId "zhost";
            name = "zhost";
            addresses = [ "tcp://${nodes.zhost.networking.primaryIPAddress}:${toString port}" ];
          }
        ];
      };
    };

  testScript = ''
    replica = "/home/alice/.o11n/allotments/zhost"

    start_all()
    zhost.wait_for_unit("allotment-sync@user-alice.zhost.service")
    laptop.wait_for_unit("allotment-sync@user-alice.zhost.service")

    with subtest("the replica is made in the principal's home, as the principal"):
        laptop.wait_until_succeeds(f"test -d {replica}/.stfolder")
        found = laptop.succeed(f"stat -c '%U %a' /home/alice/.o11n {replica}").split("\n")
        assert found[:2] == ["alice 700", "alice 700"], found

    with subtest("what the replica gets, the allotment gets, as the principal's uid"):
        laptop.succeed(f"su alice -c 'echo from-laptop > {replica}/laptop.txt'")
        zhost.wait_until_succeeds("grep -q from-laptop ${folder}/laptop.txt", timeout=120)
        assert zhost.succeed("stat -c %u ${folder}/laptop.txt").strip() == "1000"

    with subtest("and the other way"):
        zhost.succeed("setpriv --reuid=alice --regid=alice --clear-groups sh -c 'echo from-zhost > ${folder}/zhost.txt'")
        laptop.wait_until_succeeds(f"grep -q from-zhost {replica}/zhost.txt", timeout=120)

    with subtest("the allotment's host says how it syncs, through Syncthing's API on its socket"):
        import json
        def said():
            return json.loads(zhost.succeed("allotment-sync-status"))["user-alice.zhost"]
        zhost.wait_until_succeeds(
            "allotment-sync-status | jq -e '.\"user-alice.zhost\".peers.laptop | .connected and .completion == 100'",
            timeout=60,
        )
        found = said()
        assert found["errors"] == [] and found["conflicts"] == 0, found
        assert found["peers"]["laptop"]["lastSeenAgoS"] < 600, found
        zhost.succeed("setpriv --reuid=alice --regid=alice --clear-groups touch '${folder}/a.sync-conflict-20260101-000000-ABCDEFG.txt'")
        assert said()["conflicts"] == 1, said()
        laptop.succeed("systemctl stop allotment-sync@user-alice.zhost")
        zhost.wait_until_succeeds(
            "allotment-sync-status | jq -e '.\"user-alice.zhost\".peers.laptop.connected | not'", timeout=60
        )
        zhost.succeed("systemctl stop allotment-sync@user-alice.zhost")
        assert "error" in said(), said()
        zhost.succeed("systemctl start allotment-sync@user-alice.zhost")
        laptop.succeed("systemctl start allotment-sync@user-alice.zhost")

    with subtest("the allotment's host starts Syncthing once its address is there"):
        zhost.fail("journalctl -b -u allotment-sync@user-alice.zhost | grep -q 'cannot assign requested address'")

    with subtest("neither announces itself, nor listens but where it's told"):
        for machine in (zhost, laptop):
            machine.fail("ss -lunp | grep -q syncthing")
        zhost.succeed("ss -ltnp | grep syncthing | grep -q ':${toString port} '")
        laptop.fail("ss -ltnp | grep syncthing | grep -v 127.0.0.1")
  '';
}
