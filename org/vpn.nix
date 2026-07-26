# org/vpn.nix
{
  name,
  config,
  lib,
  context,
  ...
}:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "vpn";
  };

  options = {
    trusted = lib.mkOption {
      description = "disable firewalls on this vpn";
      type = lib.types.bool;
    };
    address4 = lib.mkOption {
      description = "ipv4 vpn address";
      type = context.types.subnetCidr4;
      default = "${config.prefix4}.0/${toString config.prefixLength4}";
    };
    prefix4 = lib.mkOption {
      description = "ipv4 prefix for peers in vpn";
      type = context.types.subnetPrefix4;
      default = "${context.org.prefix4}.${toString config.id}";
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 prefix length for peers in vpn";
      type = lib.types.int;
      default = context.org.prefixLength4;
    };
    address = lib.mkOption {
      description = "ipv6 vpn address";
      type = context.types.subnetCidr6;
      default = "${config.prefix}::/${toString config.prefixLength}";
    };
    addressWithBrackets = lib.mkOption {
      description = "ipv6 vpn address enclosed in square brackets";
      type = context.types.subnetCidrBracketed6;
      readOnly = true;
      default = "[${config.prefix}::]/${toString config.prefixLength}";
    };
    prefix = lib.mkOption {
      description = "ipv6 prefix for peers in vpn";
      type = context.types.subnetPrefix6;
      default = "${context.org.prefix}:${config.ids.hex4}";
    };
    prefixLength = lib.mkOption {
      description = "ipv6 prefix length for peers in vpn";
      type = lib.types.int;
      default = context.org.prefixLength;
    };
    interface = lib.mkOption {
      description = "interface for the vpn";
      type = lib.types.str;
      default = name;
    };
    namespace = lib.mkOption {
      description = "top domain in the vpns";
      type = lib.types.str;
    };
    port = lib.mkOption {
      description = "port allocated for the vpn";
      type = lib.types.port;
      default = 51820 + config.id;
    };
    keepalive = lib.mkOption {
      description = "port allocated for the vpn";
      default = 25;
      type = lib.types.int;
    };
    gateway = lib.mkOption {
      description = "designated gateway host";
      type = context.types.host.ref;
    };
    proxy = lib.mkEnableOption "ipv6 proxy through gateway";
    dns = lib.mkOption {
      description = "list of name servers";
      type = lib.types.listOf context.types.host.ref;
    };
    resetOnRebuild = lib.mkOption {
      description = "destroy and recreate network device post rebuild";
      type = lib.types.bool;
      default = true;
    };
    allowedTCPPorts = lib.mkOption {
      description = "force all peers to allow these tcp ports in the vpn";
      default = [ ];
      type = with lib.types; listOf int;
    };
    allowedUDPPorts = lib.mkOption {
      description = "force all peers to allow these udp ports in the vpn";
      default = [ ];
      type = with lib.types; listOf int;
    };
  };
}
