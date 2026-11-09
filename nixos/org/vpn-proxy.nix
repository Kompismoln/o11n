{
  config,
  host,
  lib,
  org,
  ...
}:
let
  cfg = config.o11n.vpnProxies;

  addresses = lib.concatMap (
    vpn:
    let
      network = host.network.${vpn};
    in
    lib.optional (network.address != null) "[${network.address}]"
    ++ lib.optional (network.address4 != null) network.address4
  ) host.vpns;
in
{
  options.o11n.vpnProxies = lib.mkOption {
    description = "what the host serves on each of its vpn addresses, by name, from a server that listens where only the host reaches it";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          port = lib.mkOption {
            description = "the port on each of the host's vpn addresses";
            type = lib.types.port;
          };
          to = lib.mkOption {
            description = "the server's address and port, as systemd-socket-proxyd takes them";
            type = lib.types.str;
          };
        };
      }
    );
    default = { };
  };

  config = lib.mkIf (cfg != { }) {
    networking.firewall.interfaces = lib.genAttrs (map (vpn: org.vpn.${vpn}.interface) host.vpns) (_: {
      allowedTCPPorts = lib.mapAttrsToList (_: proxy: proxy.port) cfg;
    });

    # Accommodating for the vpns, whose interfaces may come up after the sockets: FreeBind binds the addresses anyway.
    systemd.sockets = lib.mapAttrs' (
      name: proxy:
      lib.nameValuePair "${name}-vpn" {
        wantedBy = [ "sockets.target" ];
        listenStreams = map (address: "${address}:${toString proxy.port}") addresses;
        socketConfig.FreeBind = true;
      }
    ) cfg;

    systemd.services = lib.mapAttrs' (
      name: proxy:
      lib.nameValuePair "${name}-vpn" {
        description = "${name} on the host's vpns";
        requires = [ "${name}-vpn.socket" ];
        after = [ "${name}-vpn.socket" ];
        serviceConfig = {
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${proxy.to}";
          DynamicUser = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      }
    ) cfg;
  };
}
