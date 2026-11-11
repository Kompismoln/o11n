{ pkgs }:
let
  allotment = "/srv/allotments/service-torrent-server";
  address = "fd00:1::ffff:1:2001:1";
in
pkgs.testers.runNixOSTest {
  name = "o11n-media-server";

  imports = [ ./timeout.nix ];
  globalTimeout = 600;

  # Fact: eth1 stands in for the vpn, and eth2 for any other network the host is on.
  nodes.server = {
    imports = [
      ../../nixos/allotments.nix
      ../../nixos/preserve-paths.nix
      ../../nixos/services/media-server.nix
    ];
    _module.args = {
      org = {
        service.media-server = {
          name = "media-server";
          handle = "service-media-server";
          vpn = "wg0";
          principal = {
            uid = 2001;
            gid = 2001;
          };
        };
        vpn.wg0.interface = "eth1";
      };
      host = {
        name = "server";
        vpns = [ "wg0" ];
        network.wg0.principals.service-media-server = { inherit address; };
      };
    };

    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth1.ipv6.addresses = [
      {
        inherit address;
        prefixLength = 64;
      }
    ];

    users.users.media-server = {
      isSystemUser = true;
      uid = 2001;
      group = "media-server";
    };
    users.groups.media-server.gid = 2001;
    users.users.torrent-server = {
      isSystemUser = true;
      uid = 2000;
      group = "torrent-server";
    };
    users.groups.torrent-server = {
      gid = 2000;
      members = [ "media-server" ];
    };

    # Fact: Jellyfin won't start with less than 2 GiB free where it keeps its data, or its cache, which a host that
    # preserves keeps on its storage, past a root as small as this one's /var/cache.
    virtualisation.diskSize = 6144;
    o11n.preserve.enable = true;
    virtualisation.fileSystems."/var/cache" = {
      fsType = "tmpfs";
      options = [ "size=512M" ];
    };
    virtualisation.emptyDiskImages = [ 512 ];
    boot.supportedFilesystems = [ "zfs" ];
    # Fact: the test disk has no /dev/disk/by-id link, where zpool import looks by default.
    boot.zfs.devNodes = "/dev";
    networking.hostId = "8425e349";
    o11n.allotments.service-torrent-server = {
      dataset = "tank/allotments/service-torrent-server";
      size = "64M";
      path = allotment;
      uid = 2000;
      gid = 2000;
      mode = "0750";
    };
  };

  nodes.client = {
    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth1.ipv6.addresses = [
      {
        address = "fd00:1::2";
        prefixLength = 64;
      }
    ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    start_all()

    server.wait_for_unit("jellyfin")
    server.succeed("test -d /srv/storage/var/cache/media-server")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/health", timeout=120)

    with subtest("it's reached at the service's address on the vpn"):
        client.wait_until_succeeds("curl -fsS -g 'http://[${address}]:8096/health' | grep -x Healthy", timeout=60)

    with subtest("and not on another network"):
        lan = server.succeed("ip -4 -o addr show eth2 | awk '{print $4}' | cut -d/ -f1").strip()
        client.fail(f"curl -fsS --max-time 5 http://{lan}:8096/health")

    with subtest("it reads an allotment whose principal's group it's a member of"):
        server.succeed(
            "zpool create -O mountpoint=none tank /dev/vdb",
            "systemctl restart allotment@service-torrent-server",
            "echo film > ${allotment}/film.mkv",
            "chown torrent-server: ${allotment}/film.mkv",
        )
        assert server.succeed("stat -c %a ${allotment}").strip() == "750"
        user = server.succeed("systemctl show -P User jellyfin").strip()
        assert user == "media-server", user
        assert server.succeed(
            "systemd-run --wait --pipe --quiet -p User=media-server -p PrivateUsers=true cat ${allotment}/film.mkv"
        ).strip() == "film"
        server.fail("systemd-run --wait --pipe --quiet -p User=nobody cat ${allotment}/film.mkv")
  '';
}
