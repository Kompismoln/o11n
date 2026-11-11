{ pkgs }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  library = "/srv/allotments/service-media-server";
  address = "fd00:1::ffff:1:2001:1";
  arrs = {
    radarr = {
      port = 7878;
      api = "v3";
      kind = "movies";
      rename = "renameMovies";
    };
    sonarr = {
      port = 8989;
      api = "v3";
      kind = "tv";
      rename = "renameEpisodes";
    };
    lidarr = {
      port = 8686;
      api = "v1";
      kind = "music";
      rename = "renameTracks";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "o11n-media-server";

  imports = [ ./timeout.nix ];
  globalTimeout = 900;

  # Fact: eth1 stands in for the vpn, and eth2 for any other network the host is on.
  nodes.server = {
    imports = [
      ../../nixos/allotments.nix
      ../../nixos/preserve-paths.nix
      ../../nixos/services/torrent-server.nix
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
        service.torrent-server = {
          name = "torrent-server";
          handle = "service-torrent-server";
          principal = {
            uid = 2000;
            gid = 2000;
          };
          publicKeys.ssh-key = builtins.toFile "ssh-key.pub" keys.snakeOilEd25519PublicKey;
        };
        entities.service-media-server.principal = {
          uid = 2001;
          gid = 2001;
        };
        vpn.wg0.interface = "eth1";
      };
      host = {
        name = "server";
        vpns = [ "wg0" ];
        network.wg0.principals.service-media-server = { inherit address; };
        services = [
          { name = "torrent-server"; }
          { name = "media-server"; }
        ];
        allotments = [
          {
            entity = "service-media-server";
            path = library;
            torrent = true;
          }
        ];
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
    users.groups.torrent-server.gid = 2000;

    # Fact: Jellyfin won't start with less than 2 GiB free where it keeps its data, or its cache, which a host that
    # preserves keeps on its storage, past a root as small as this one's /var/cache.
    virtualisation.diskSize = 6144;
    virtualisation.memorySize = 4096;
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
    o11n.allotments.service-media-server = {
      dataset = "tank/allotments/service-media-server";
      size = "64M";
      path = library;
      uid = 2001;
      gid = 2001;
    };

    services.transmission.settings.dht-enabled = false;
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
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
    import base64
    import json

    arrs = json.loads('${builtins.toJSON arrs}')

    def api(app, path, method="GET", data=None):
        arr = arrs[app]
        key = server.succeed(
            f"sed -n 's:.*<ApiKey>\\(.*\\)</ApiKey>.*:\\1:p' /srv/storage/var/lib/media-server-{app}/config.xml"
        ).strip()
        url = f"http://127.0.0.1:{arr['port']}/api/{arr['api']}/{path}"
        if data is None:
            return server.succeed(f"curl -fsS -X {method} -H 'X-Api-Key: {key}' {url}")
        body = base64.b64encode(json.dumps(data).encode()).decode()
        return server.succeed(
            f"echo {body} | base64 -d | curl -sS --fail-with-body -X {method} -H 'X-Api-Key: {key}' -H 'Content-Type: application/json' --data @- {url}"
        )

    start_all()

    with subtest("its library and what downloads into it start once the allotment is there"):
        server.wait_for_unit("multi-user.target")
        server.succeed(
            "zpool create -O mountpoint=none tank /dev/vdb",
            "systemctl restart allotment@service-media-server",
            "systemctl start transmission",
        )
        server.wait_for_unit("transmission")
        for app in arrs:
            server.succeed(f"systemctl restart media-server-{app}-setup")

    server.wait_for_unit("jellyfin")
    server.succeed("test -d /srv/storage/var/cache/media-server")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/health", timeout=120)

    with subtest("each *arr files its kind in the library, from its directory of the downloads, through Transmission"):
        for app, arr in arrs.items():
            roots = [folder["path"].rstrip("/") for folder in json.loads(api(app, "rootfolder"))]
            assert roots == [f"${library}/{arr['kind']}"], roots
            clients = json.loads(api(app, "downloadclient"))
            assert [client["name"] for client in clients] == ["torrent-server"], clients
            fields = {field["name"]: field.get("value") for field in clients[0]["fields"]}
            directories = [value for name, value in fields.items() if name.lower().endswith("directory")]
            assert directories == [f"${library}/downloads/{arr['kind']}"], fields
            api(app, "downloadclient/test", "POST", clients[0])
            assert json.loads(api(app, "config/naming"))[arr["rename"]] is True
            consumers = json.loads(api(app, "metadata"))
            assert [c["enable"] for c in consumers if c["implementation"] == "XbmcMetadata"] == [True], consumers
            assert server.succeed(f"stat -c %U ${library}/downloads/{arr['kind']}").strip() == "media-server"

    with subtest("each setup runs again as it did"):
        for app in arrs:
            server.succeed(f"systemctl restart media-server-{app}-setup")
            assert len(json.loads(api(app, "downloadclient"))) == 1
            assert len(json.loads(api(app, "rootfolder"))) == 1

    with subtest("what the torrent-server writes is the library's, which an *arr links into its kind"):
        server.succeed(
            "systemd-run --wait --pipe --quiet -p User=torrent-server -p BindPaths=/run/torrent-server/service-media-server:/mnt sh -c 'echo film > /mnt/downloads/movies/film.mkv'"
        )
        assert server.succeed("stat -c %U:%G ${library}/downloads/movies/film.mkv").strip() == "media-server:media-server"
        server.succeed(
            "systemd-run --wait --pipe --quiet -p User=media-server ln ${library}/downloads/movies/film.mkv ${library}/movies/film.mkv"
        )
        assert server.succeed("stat -c %h ${library}/movies/film.mkv").strip() == "2"
        server.fail("systemd-run --wait --pipe --quiet -p User=torrent-server cat ${library}/movies/film.mkv")

    with subtest("it's reached at the service's address on the vpn, Jellyfin and each *arr"):
        client.wait_until_succeeds("curl -fsS -g 'http://[${address}]:8096/health' | grep -x Healthy", timeout=60)
        for arr in arrs.values():
            client.wait_until_succeeds(f"curl -fsS -g 'http://[${address}]:{arr['port']}/ping' | grep -q OK", timeout=60)

    with subtest("and not on another network"):
        lan = server.succeed("ip -4 -o addr show eth2 | awk '{print $4}' | cut -d/ -f1").strip()
        client.fail(f"curl -fsS --max-time 5 http://{lan}:8096/health")
        client.fail(f"curl -fsS --max-time 5 http://{lan}:7878/ping")
  '';
}
