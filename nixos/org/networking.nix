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
      DHCP = if network.suffix == null then "yes" else "ipv4";
    }
    // lib.optionalAttrs (network.privacy != null) {
      IPv6PrivacyExtensions = if network.privacy then "kernel" else "no";
    };
    ipv6AcceptRAConfig = lib.mkIf (network.suffix != null) {
      Token = "static:${network.suffix}";
      DHCPv6Client = "no";
    };
  };

  suffixed = lib.filter (network: network.suffix != null) (lib.attrValues host.network);

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

  # Policy: names are the org's DNS's, not asked of a link.
  services.resolved.settings.Resolve.LLMNR = "false";

  networking = {
    hostId = host.ids.hex8;
    localCommands = ''
      ip -6 route replace local ${org.loCidr} dev lo
      ${lib.concatMapStrings (
        vpn:
        lib.concatMapStrings (principal: "ip -6 route replace local ${principal.address}/128 dev lo\n") (
          lib.attrValues host.network.${vpn}.principals
        )
      ) host.vpns}'';
    useNetworkd = true;
    useDHCP = false;
    firewall = {
      logRefusedConnections = false;
    };
  };
  assertions = lib.concatMap (network: [
    {
      assertion = network.mode == "dhcp";
      message = "${host.name}'s network ${network.type} has a suffix, which only a dhcp network takes: remove it, or set mode = \"dhcp\".";
    }
    {
      assertion =
        lib.count (other: other.suffix == network.suffix) suffixed == 1
        && lib.all (
          other:
          other.name == host.name
          || lib.all (theirs: theirs.suffix != network.suffix) (lib.attrValues other.network)
        ) (lib.attrValues org.host);
      message = "${host.name}'s network ${network.type} has the suffix ${network.suffix}, as another network does, which could share its link and prefix: give each its own.";
    }
  ]) suffixed;

  systemd.network = {
    enable = true;
    networks = lib.listToAttrs (
      map (network: lib.nameValuePair "10-${network.interface}" (mkNetwork network)) (
        builtins.filter (network: network.mode != null) (lib.attrValues host.network)
      )
    );
  };
}
