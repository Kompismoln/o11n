{
  config,
  host,
  lib,
  org,
  ...
}:
let
  service = org.service.media-server;
  inherit (service) name vpn;
  inherit (service.principal) uid gid;

  served = vpn != null && lib.elem vpn host.vpns;
  inherit (host.network.${vpn}.principals.${service.handle}) address;

  # Fact: Jellyfin answers http on 8096, on every IPv4 address, and on IPv6 only once its own network.xml enables it,
  # which would take the service's address from the socket.
  port = 8096;
  upstream = "127.0.0.1:${toString port}";
  dataDir = config.o11n.preserve.onStorage "/var/lib/${name}";
  # Fact: Jellyfin won't start with less than 2 GiB free for its cache either, which a host's ephemeral root may not
  # have.
  cacheDir = config.o11n.preserve.onStorage "/var/cache/${name}";
in
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
  ];

  services.jellyfin = {
    enable = true;
    user = name;
    group = name;
    inherit dataDir;
    inherit cacheDir;
  };

  systemd.tmpfiles.rules = [
    "d '${dataDir}' 0700 ${toString uid} ${toString gid} - -"
    "d '${cacheDir}' 0700 ${toString uid} ${toString gid} - -"
  ];

  networking.firewall.interfaces = lib.mkIf served {
    ${org.vpn.${vpn}.interface}.allowedTCPPorts = [ port ];
  };

  # Accommodating for the vpn, whose interface may come up after the socket: FreeBind binds the address anyway.
  systemd.sockets.media-server = lib.mkIf served {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "[${address}]:${toString port}" ];
    socketConfig.FreeBind = true;
  };

  systemd.services.media-server = lib.mkIf served {
    description = "the media-server's address on ${vpn}, to Jellyfin";
    requires = [
      "media-server.socket"
      "jellyfin.service"
    ];
    after = [
      "media-server.socket"
      "jellyfin.service"
    ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${upstream}";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
