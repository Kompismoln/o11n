{ pkgs }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  file = pkgs.hello.src;
  allotment = "/srv/allotments/user-alice";
  seeding = "/var/lib/transmission/Downloads";
in
pkgs.testers.runNixOSTest {
  name = "o11n-torrent-server";

  imports = [ ./timeout.nix ];
  globalTimeout = 600;

  nodes.tracker = {
    networking.firewall.enable = false;
    services.opentracker.enable = true;
    services.httpd = {
      enable = true;
      virtualHosts.tracker = {
        adminAddr = "admin@example.org";
        documentRoot = "/srv/www";
      };
    };
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      settings = {
        dht-enabled = false;
        download-dir = seeding;
      };
    };
  };

  nodes.server = {
    imports = [
      ../../nixos/allotments.nix
      ../../nixos/preserve-paths.nix
      ../../nixos/services/torrent-server.nix
    ];
    _module.args = {
      org.service.torrent-server = {
        name = "torrent-server";
        handle = "service-torrent-server";
        principal = {
          uid = 2000;
          gid = 2000;
        };
        hosts.server = {
          upload = 200;
          download = null;
          ratio = 2;
          peerPort = 51413;
        };
        publicKeys.ssh-key = builtins.toFile "ssh-key.pub" keys.snakeOilEd25519PublicKey;
      };
      org.entities.user-alice.principal = {
        uid = 1000;
        gid = 1000;
      };
      host = {
        name = "server";
        allotments = [
          {
            entity = "user-alice";
            path = allotment;
            torrent = true;
          }
        ];
      };
    };

    users.users.torrent-server = {
      isSystemUser = true;
      uid = 2000;
      group = "torrent-server";
    };
    users.groups.torrent-server.gid = 2000;
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
      group = "alice";
    };
    users.groups.alice.gid = 1000;

    virtualisation.emptyDiskImages = [ 512 ];
    boot.supportedFilesystems = [ "zfs" ];
    # Fact: the test disk has no /dev/disk/by-id link, where zpool import looks by default.
    boot.zfs.devNodes = "/dev";
    networking.hostId = "8425e349";
    o11n.allotments.user-alice = {
      dataset = "tank/storage/allotments/user-alice";
      size = "64M";
      path = allotment;
      uid = 1000;
      gid = 1000;
    };
    o11n.torrent-server.kinds.films = "${allotment}/films";

    services.transmission.settings.dht-enabled = false;
    services.openssh.enable = true;
    environment.etc."operator/ssh-key" = {
      source = keys.snakeOilEd25519PrivateKey;
      mode = "0600";
    };
  };

  testScript = ''
    def control(command):
        return server.succeed(
            "ssh -i /etc/operator/ssh-key -o StrictHostKeyChecking=no torrent-server@localhost " + command
        )

    start_all()

    with subtest("the server starts once the allotment it downloads into is there"):
        server.wait_for_unit("multi-user.target")
        server.fail("systemctl is-active transmission")
        server.succeed(
            "zpool create -O mountpoint=none tank /dev/vdb",
            "zfs create -o mountpoint=/srv/storage tank/storage",
            "systemctl restart allotment@user-alice",
            "systemctl start transmission",
        )
        server.wait_for_unit("transmission")
        server.wait_for_open_port(9091)

    with subtest("it limits its uploads and seeding as the org says"):
        session = server.succeed("transmission-remote 127.0.0.1:9091 --session-info")
        assert "Upload speed limit: 200 kB/s" in session, session
        assert "Default seed ratio limit: 2.00" in session, session

    with subtest("its ssh-key runs control alone"):
        assert "torrent-server: add [--to <allotment>|--as <kind>] <link|->" in server.fail(
            "ssh -i /etc/operator/ssh-key -o StrictHostKeyChecking=no torrent-server@localhost id 2>&1"
        )

    tracker.wait_for_unit("opentracker")
    tracker.wait_for_open_port(6969)
    tracker.wait_for_unit("transmission")
    tracker.wait_for_unit("httpd")
    tracker.succeed(
        "mkdir -p ${seeding} /srv/www",
        "cp ${file} ${seeding}/hello.tar.gz",
        "chown -R transmission: ${seeding}",
        "transmission-create ${seeding}/hello.tar.gz --private --tracker http://tracker:6969/announce --outfile /srv/www/hello.torrent",
        "chmod 644 /srv/www/hello.torrent",
        "transmission-remote --add /srv/www/hello.torrent --no-dht --download-dir ${seeding}",
    )

    with subtest("a .torrent sent on stdin downloads into the allotment, as its principal's"):
        server.succeed("curl -fsS http://tracker/hello.torrent -o /tmp/hello.torrent")
        control("add - < /tmp/hello.torrent")
        server.wait_for_file("${allotment}/hello.tar.gz")
        server.wait_until_succeeds("cmp ${allotment}/hello.tar.gz ${file}", timeout=120)
        assert server.succeed("stat -c %u:%g ${allotment}/hello.tar.gz").strip() == "1000:1000"
        assert "hello.tar.gz" in control("list")

    with subtest("it seeds what it downloaded, and the principal owns it"):
        server.wait_until_succeeds("transmission-remote 127.0.0.1:9091 --torrent 1 --info | grep -Eq 'State: (Seeding|Idle)'", timeout=60)
        server.succeed("su alice -c 'ln ${allotment}/hello.tar.gz ${allotment}/linked.tar.gz'")
        server.fail("su torrent-server -s /bin/sh -c 'cat ${allotment}/hello.tar.gz'")

    with subtest("--as and --to file a download where they say, and nowhere else"):
        assert "--to names an allotment the server downloads into: user-alice" in server.fail(
            "ssh -i /etc/operator/ssh-key -o StrictHostKeyChecking=no torrent-server@localhost add --to user-bob - < /tmp/hello.torrent 2>&1"
        )
        control("remove 1")
        control("add --as films - < /tmp/hello.torrent")
        server.wait_until_succeeds("cmp ${allotment}/films/hello.tar.gz ${file}", timeout=120)
        assert server.succeed("stat -c %u ${allotment}/films").strip() == "1000"

    with subtest("removed with --delete, what it downloaded goes too"):
        control("remove --delete 2")
        server.wait_until_fails("test -e ${allotment}/films/hello.tar.gz")
        assert "hello.tar.gz" not in control("list")
        server.succeed("test -e ${allotment}/hello.tar.gz")
  '';
}
