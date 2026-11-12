# Optimization: two parts, as `part` names, each a VM test of its own, so that they run side by side: how changes are
# followed, and how the following recovers.
{
  pkgs,
  o11nInputs,
  outputs,
  part,
}:
let
  inherit (pkgs) lib;
  # Accommodating for the inventory, which runs no app but declares it, and names no postgresql to run it with.
  org = outputs.org // {
    postgres = "17";
  };
  # Fact: the app with its mount of alice's allotment alone, as lisa's would need store-files' sftp-key.
  cloud = lib.recursiveUpdate org.app.cloud {
    nextcloud.mounts.laptop = lib.filter (
      mount: mount.user == "alice"
    ) org.app.cloud.nextcloud.mounts.laptop;
  };
  alice = org.user.alice;

  port = 23000;
  id = "user-alice.zhost";
  folder = "/srv/allotments/user-alice";
  replica = "/home/alice/.o11n/allotments/zhost";
  changes = "/run/allotment-changes/${id}";
  # Fact: the addresses tests/inventories/allotments gives zhost and laptop on wg0, which nextcloud's mount and the
  # login it follows changes by have.
  address4 = {
    zhost = "10.0.0.1";
    laptop = "10.0.0.2";
  };
  deviceId =
    host:
    lib.trim (builtins.readFile ../inventories/allotments/public-keys/host-${host}-syncthing-${id}.pub);

  # Fact: the inventory's secrets, decrypted, which protect nothing.
  pem = host: {
    environment.etc."allotment-sync.pem" = {
      source = ./allotment-sync/${host}.pem;
      mode = "0400";
      user = "alice";
      group = "alice";
    };
  };

  wg0 = host: {
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = address4.${host};
        prefixLength = 24;
      }
    ];
  };

  principal = entity: {
    users.users.${entity.name} = {
      isSystemUser = true;
      group = entity.name;
      inherit (entity.principal) uid home;
      createHome = true;
    };
    users.groups.${entity.name}.gid = entity.principal.gid;
  };

  # Accommodating for sops-nix, which this test doesn't run: what the app declares there is only declared, and its
  # sftp-key and a secret-key are installed at the paths sops-nix would give them.
  sops =
    { lib, ... }:
    {
      options.sops = {
        secrets = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                freeformType = lib.types.attrsOf lib.types.anything;
                options.path = lib.mkOption { default = "/run/secrets/${name}"; };
              }
            )
          );
          default = { };
        };
        templates = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
      config.system.activationScripts.sftp-key = ''
        install -D -m 0400 -o ${cloud.name} -g ${cloud.name} ${./nextcloud-changes/app-cloud-sftp-key} \
          /run/secrets/${cloud.name}/app-cloud/sftp-key
        install -D -m 0400 -o ${cloud.name} -g ${cloud.name} ${builtins.toFile "secret-key" "o11n-test-secret-key"} \
          /run/secrets/${cloud.name}/secret-key
      '';
    };

  nextcloud =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    import ../../nixos/apps/nextcloud.nix {
      app = cloud;
      host = org.host.laptop;
      inherit
        config
        lib
        org
        pkgs
        ;
    };

  parts = {
    follows = ''
      with subtest("what the replica changes, nextcloud knows of, without a folder opened or a scan run"):
          laptop.succeed("su alice -c 'echo from-laptop > ${replica}/from-laptop.txt'")
          zhost.wait_until_succeeds("test -e ${folder}/from-laptop.txt", timeout=120)
          wait_cached("from-laptop.txt")
          laptop.succeed("su alice -c 'mkdir -p ${replica}/deep/er && echo deep > ${replica}/deep/er/deep.txt'")
          wait_cached("deep.txt")

      with subtest("what another writer changes on the allotment's host isn't a change of the replicas'"):
          zhost.succeed("runuser -u alice -- sh -c 'echo local > ${folder}/local.txt'")
          laptop.wait_until_succeeds("test -e ${replica}/local.txt", timeout=120)
          laptop.sleep(10)
          assert not cached("local.txt")

      with subtest("nextcloud checks a folder for changes as it's opened"):
          laptop.succeed(
              "curl -sSf -o /dev/null -X PROPFIND -H 'Depth: 1' -H 'Host: ${cloud.endpoint}' -u alice:alice-password"
              " 'http://[${cloud.principal.bindAddress}]:4000/remote.php/dav/files/alice/zhost/'"
          )
          assert cached("local.txt")

      with subtest("the login follows the allotments its key may, and nothing else"):
          ssh = (
              "ssh -T -i /run/secrets/${cloud.name}/app-cloud/sftp-key -o IdentitiesOnly=yes -o BatchMode=yes"
              " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null allotment-changes@${address4.zhost}"
          )
          refused = laptop.fail(f"{ssh} other.zhost 2>&1")
          assert "this key follows ${id}, and not 'other.zhost'" in refused, refused
          assert laptop.succeed(f"timeout 5 {ssh} ${id} || true").strip() == "changed"

      with subtest("o11n status says the listener is ok once it has been connected for a while"):
          laptop.wait_until_succeeds("nextcloud-status-${cloud.name} | grep -qx '${cloud.name} changes alice/zhost ok'", timeout=60)
    '';

    recovers = ''
      with subtest("it catches up as it reconnects"):
          zhost.succeed("systemctl stop sshd.service")
          laptop.succeed(f"nixos-container run ${cloud.name} -- systemctl restart {listener}")
          laptop.wait_until_fails(f"nixos-container run ${cloud.name} -- systemctl is-active {listener}", timeout=60)
          laptop.succeed("su alice -c 'echo while-away > ${replica}/while-away.txt'")
          zhost.wait_until_succeeds("test -e ${folder}/while-away.txt", timeout=120)
          zhost.succeed("systemctl start sshd.service")
          wait_cached("while-away.txt")

      with subtest("a scan that fails, the listener scans again until one doesn't, and o11n status says so meanwhile"):
          zhost.succeed("mv /etc/ssh/authorized_keys.d/alice /root/alice-keys")
          laptop.succeed("su alice -c 'echo while-failing > ${replica}/while-failing.txt'")
          zhost.wait_until_succeeds("test -e ${folder}/while-failing.txt", timeout=120)
          laptop.wait_until_succeeds(f"journalctl -M ${cloud.name} -u {listener} | grep -q '| Errors |'", timeout=60)
          laptop.wait_until_succeeds(
              "nextcloud-status-${cloud.name} | grep -q '^${cloud.name} changes alice/zhost nextcloud-changes-alice-zhost.service '",
              timeout=60,
          )
          assert not cached("while-failing.txt")
          zhost.succeed("mv /root/alice-keys /etc/ssh/authorized_keys.d/alice")
          # Accommodating for nextcloud, which skips a storage it failed to log in to for 30 minutes.
          laptop.succeed("runuser -u postgres -- psql -d ${cloud.database} -c 'update oc_storages set available = 1'")
          wait_cached("while-failing.txt")
          laptop.wait_until_succeeds("nextcloud-status-${cloud.name} | grep -qx '${cloud.name} changes alice/zhost ok'", timeout=60)
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "o11n-nextcloud-changes" + lib.optionalString (part == "recovers") "-recovery";

  imports = [ ./timeout.nix ];
  globalTimeout = 900;

  node.specialArgs = { inherit org o11nInputs; };

  nodes.zhost =
    { config, ... }:
    {
      imports = [
        ../../nixos/allotment-sync.nix
        ../../nixos/allotment-changes.nix
        (pem "zhost")
        (wg0 "zhost")
      ];
      users.users.alice = {
        isNormalUser = true;
        inherit (alice.principal) uid;
        group = "alice";
        openssh.authorizedKeys.keyFiles = [ ../inventories/allotments/public-keys/app-cloud-sftp-key.pub ];
      };
      users.groups.alice.gid = alice.principal.gid;
      networking.useNetworkd = true;
      networking.firewall.allowedTCPPorts = [
        22
        port
      ];
      systemd.tmpfiles.rules = [
        "d ${folder} 0700 alice alice - -"
        "d /var/lib/allotment-sync/${id} 0700 alice alice - -"
      ];
      o11n.allotment-sync.${id} = {
        inherit folder changes;
        state = "/var/lib/allotment-sync/${id}";
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
      o11n.allotment-changes.app-cloud = {
        key = lib.trim (builtins.readFile ../inventories/allotments/public-keys/app-cloud-sftp-key.pub);
        from = [ "${address4.laptop}/32" ];
        ids = [ id ];
      };
      # Fact: as nixos/org/allotments.nix has the allotment's host for nextcloud's SFTP, with the inventory's host key,
      # which the app verifies as it follows changes.
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = ./nextcloud-changes/zhost-ssh-key;
        mode = "0600";
      };
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
          {
            path = "/etc/ssh/ssh_host_rsa_key";
            type = "rsa";
            bits = 2048;
          }
        ];
        settings.Macs = lib.mkOptionDefault [ "hmac-sha2-256" ];
        extraConfig = ''
          Match User alice
            ChrootDirectory ${dirOf folder}
            ForceCommand internal-sftp -d /${baseNameOf folder}
        '';
      };
    };

  nodes.laptop =
    { nodes, ... }:
    {
      _module.args.host = org.host.laptop;
      imports = [
        ../../nixos/allotment-sync.nix
        ../../nixos/preserve.nix
        (pem "laptop")
        (wg0 "laptop")
        sops
        nextcloud
        (principal cloud)
      ];
      users.users.alice = {
        isNormalUser = true;
        inherit (alice.principal) uid;
        group = "alice";
      };
      users.groups.alice.gid = alice.principal.gid;
      o11n.allotment-sync.${id} = {
        folder = replica;
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
      # Accommodating for the test's network, which has no ACME server: nothing reaches nextcloud but through its
      # container's own nginx.
      services.nginx.enable = true;
      services.nginx.virtualHosts.${cloud.endpoint} = {
        forceSSL = lib.mkForce false;
        enableACME = lib.mkForce false;
      };
      # Accommodating for the test's network, which has no wg0: the principal binds to its loopback address as
      # nixos/org/networking.nix routes it.
      networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
      boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
    };

  testScript = ''
    listener = "nextcloud-changes-alice-zhost.service"

    def cached(name):
        return laptop.succeed(
            f"runuser -u postgres -- psql -d ${cloud.database} -tAc \"select count(*) from oc_filecache where name = '{name}'\""
        ).strip() == "1"

    def wait_cached(name):
        laptop.wait_until_succeeds(
            f"runuser -u postgres -- psql -d ${cloud.database} -tAc \"select count(*) from oc_filecache where name = '{name}'\" | grep -qx 1",
            timeout=120,
        )

    start_all()
    zhost.wait_for_unit("allotment-changes@${id}.service")
    laptop.wait_for_unit("allotment-sync@${id}.service")
    laptop.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-external.service", timeout=600)
    laptop.succeed("nixos-container run ${cloud.name} -- env OC_PASS=alice-password nextcloud-occ user:resetpassword --password-from-env alice")
    laptop.wait_until_succeeds(f"nixos-container run ${cloud.name} -- systemctl is-active {listener}", timeout=120)
    laptop.wait_until_succeeds("test -d ${replica}/.stfolder", timeout=120)

  ''
  + parts.${part};
}
