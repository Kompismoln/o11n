{
  lib,
  host,
  org,
  ...
}:
let
  mkNetwork =
    network:
    {
      static = mkStatic network;
      dhcp = mkDhcp network;
    }
    .${network.mode};

  mkDhcp = network: {
    matchConfig.Name = network.interface;
    dhcpV4Config = {
      RouteMetric = network.metric4;
    };
    networkConfig = {
      DHCP = "yes";
    }
    // lib.optionalAttrs (network.privacy != null) {
      IPv6PrivacyExtensions = if network.privacy then "kernel" else "no";
    };
  };

  mkStatic = network: {
    matchConfig.Name = network.interface;
    networkConfig = {
      Address = [
        "${network.address}/${toString network.prefixLength}"
        "${network.address4}/${toString network.prefixLength4}"
      ];
      DNS = network.dns;
    };
    routes = [
      {
        Destination = network.destination4;
        Gateway = network.gateway4;
        GatewayOnLink = network.gatewayOnLink;
        Metric = network.metric4;
      }
      {
        Destination = network.destination;
        Gateway = network.gateway;
        GatewayOnLink = network.gatewayOnLink;
        Metric = network.metric;
      }
    ];
  };
in
{
  boot.kernel.sysctl = {
    "net.ipv6.ip_nonlocal_bind" = 1;
  };

  hardware.facter.detected.dhcp = {
    interfaces = [ ];
  };

  networking = {
    hostId = host.ids.hex8;
    localCommands =
      let
        loCidr = "${org.loPrefix}::/${toString org.prefixLength}";
      in
      ''
        ip -6 route add local ${loCidr} dev lo
      '';
    useNetworkd = true;
    useDHCP = false;
    firewall = {
      logRefusedConnections = false;
    };
  };
  systemd.network = {
    enable = true;
    networks = lib.listToAttrs (
      map (network: lib.nameValuePair "10-${network.interface}" (mkNetwork network)) (
        builtins.filter (network: network.mode != null) (lib.attrValues host.network)
      )
    );
  };
}
