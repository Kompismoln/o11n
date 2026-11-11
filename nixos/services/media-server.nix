{
  config,
  host,
  lib,
  options,
  org,
  pkgs,
  ...
}:
let
  service = org.service.media-server;
  inherit (service) name vpn;
  inherit (service.principal) uid gid;

  served = vpn != null && lib.elem vpn host.vpns;
  inherit (host.network.${vpn}.principals.${service.handle}) address;

  library = lib.findFirst (allotment: allotment.entity == service.handle) null host.allotments;
  libraryUnit = "allotment@${service.handle}.service";
  downloads = "${library.path}/downloads";
  torrents = lib.any (service: service.name == "torrent-server") host.services;

  # Fact: Jellyfin answers http on 8096, on every IPv4 address, and on IPv6 only once its own network.xml enables it,
  # which would take the service's address from the socket.
  jellyfin = 8096;
  dataDir = config.o11n.preserve.onStorage "/var/lib/${name}";
  # Fact: Jellyfin won't start with less than 2 GiB free for its cache either, which a host's ephemeral root may not
  # have.
  cacheDir = config.o11n.preserve.onStorage "/var/cache/${name}";

  # Policy: each *arr files what it takes of the downloads in its kind's directory of the library, which Jellyfin's
  # libraries are, by a hardlink, as both are in one allotment.
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

  arrDir = app: config.o11n.preserve.onStorage "/var/lib/${name}-${app}";
  kindDir = arr: "${downloads}/${arr.kind}";

  ports = {
    inherit jellyfin;
  }
  // lib.mapAttrs (_: arr: arr.port) arrs;

  setup =
    app: arr:
    lib.nameValuePair "${name}-${app}-setup" {
      description = "${app}'s library, downloads and metadata";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "${app}.service"
        libraryUnit
      ];
      after = [
        "${app}.service"
        "transmission.service"
        libraryUnit
      ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnused
        pkgs.jq
      ];
      environment = {
        APP = app;
        API = arr.api;
        URL = "http://127.0.0.1:${toString arr.port}";
        CONFIG = "${arrDir app}/config.xml";
        ROOT = "${library.path}/${arr.kind}";
        DOWNLOADS = kindDir arr;
        RENAME = arr.rename;
        TRANSMISSION_PORT = toString config.services.transmission.settings.rpc-port;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = name;
        Group = name;
      };
      script = ''
        set -euo pipefail
        ${builtins.readFile ./media-server-setup.sh}
      '';
    };

  # Accommodating for the vpn, whose interface may come up after the socket: FreeBind binds the address anyway.
  socket = port: {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "[${address}]:${toString port}" ];
    socketConfig.FreeBind = true;
  };

  proxy = app: port: {
    description = "the media-server's address on ${vpn}, to ${app}";
    requires = [
      "${name}-${app}.socket"
      "${app}.service"
    ];
    after = [
      "${name}-${app}.socket"
      "${app}.service"
    ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString port}";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
in
lib.mkMerge [
  {
    assertions = [
      {
        assertion = vpn != null;
        message = "The media-server serves on one vpn: set vpn under [service.media-server].";
      }
      {
        assertion = vpn == null || lib.elem vpn host.vpns;
        message = "The media-server serves on ${toString vpn}, which ${host.name} isn't on: add it to ${host.name}'s vpns.";
      }
      {
        assertion = library != null;
        message = "service.media-server on ${host.name}: its library is an allotment of its own, and ${host.name} has none: add allotment.\"${service.handle}@${host.name}\" with its size and torrent = true.";
      }
      {
        assertion = torrents && (library == null || library.torrent);
        message = "service.media-server on ${host.name}: Radarr, Sonarr and Lidarr take what the torrent-server on ${host.name} downloads into the library: give ${host.name} a role with the torrent-server, and set torrent = true on allotment.\"${service.handle}@${host.name}\".";
      }
    ];

    services = {
      jellyfin = {
        enable = true;
        user = name;
        group = name;
        inherit dataDir cacheDir;
      };
    }
    // lib.mapAttrs (app: arr: {
      enable = true;
      user = name;
      group = name;
      dataDir = arrDir app;
      settings = {
        server = {
          inherit (arr) port;
          bindaddress = "127.0.0.1";
        };
        # Policy: the vpn alone keeps others from the *arrs, as it does from Jellyfin's setup.
        auth.method = "External";
      };
    }) arrs;

    systemd.tmpfiles.rules = map (dir: "d '${dir}' 0700 ${toString uid} ${toString gid} - -") (
      [
        dataDir
        cacheDir
      ]
      ++ lib.mapAttrsToList (app: _: arrDir app) arrs
    );

    systemd.services = lib.mkMerge [
      (lib.mkIf (library != null) (lib.listToAttrs (lib.mapAttrsToList setup arrs)))
      (lib.mkIf (library != null) (
        lib.mapAttrs (_: _: {
          wants = [ libraryUnit ];
          after = [ libraryUnit ];
        }) arrs
      ))
      (lib.mkIf served (
        lib.mapAttrs' (app: port: lib.nameValuePair "${name}-${app}" (proxy app port)) ports
      ))
    ];

    systemd.sockets = lib.mkIf served (
      lib.mapAttrs' (app: port: lib.nameValuePair "${name}-${app}" (socket port)) ports
    );

    networking.firewall.interfaces = lib.mkIf served {
      ${org.vpn.${vpn}.interface}.allowedTCPPorts = lib.attrValues ports;
    };
  }
  (lib.optionalAttrs (options.o11n ? torrent-server) {
    o11n.torrent-server = lib.mkIf (library != null && library.torrent) {
      targets.${service.handle} = downloads;
      kinds = lib.mapAttrs' (_: arr: lib.nameValuePair arr.kind (kindDir arr)) arrs;
      default = downloads;
    };
  })
]
