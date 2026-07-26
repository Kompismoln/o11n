# org/network.nix
{
  name,
  config,
  lib,
  context,
  ...
}:
{
  options = {
    type = lib.mkOption {
      description = "network type";
      default = name;
      type = lib.types.str;
    };
    interface = lib.mkOption {
      description = "interface associated with the network";
      type = lib.types.str;
    };
    mode = lib.mkOption {
      type =
        with lib.types;
        nullOr (enum [
          "dhcp"
          "static"
        ]);
      default = null;
    };
    mac = lib.mkOption {
      description = "mac address";
      type = lib.types.nullOr context.types.mac;
      default = null;
    };
    address = lib.mkOption {
      description = "ipv6 host address (not CIDR)";
      type = with lib.types; nullOr str;
      default = null;
    };
    destination = lib.mkOption {
      description = "ipv6 destination";
      type = with lib.types; nullOr str;
      default = null;
    };
    prefixLength = lib.mkOption {
      description = "ipv6 prefix length";
      type = with lib.types; nullOr int;
      default = null;
    };
    gateway = lib.mkOption {
      description = "ipv6 gateway address";
      type = with lib.types; nullOr str;
      default = null;
    };
    metric = lib.mkOption {
      description = "ipv6 metric for routing: lower takes priority";
      type = with lib.types; nullOr int;
      default = 1024;
    };
    address4 = lib.mkOption {
      description = "ipv4 host address";
      type = with lib.types; nullOr str;
      default = null;
    };
    destination4 = lib.mkOption {
      description = "ipv4 destination";
      type = with lib.types; nullOr str;
      default = null;
    };
    gateway4 = lib.mkOption {
      description = "ipv4 gateway address";
      type = with lib.types; nullOr str;
      default = null;
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 prefix length";
      type = with lib.types; nullOr int;
      default = null;
    };
    metric4 = lib.mkOption {
      description = "ipv4 metric for routing: lower takes priority";
      type = with lib.types; nullOr int;
      default = config.metric;
    };
    dns = lib.mkOption {
      type = with lib.types; nullOr (listOf str);
      default = null;
    };
    gatewayOnLink = lib.mkEnableOption "onlink for gateway" // {
      type = with lib.types; nullOr bool;
      default = null;
    };
    privacy = lib.mkEnableOption "ipv6 kernel address rotation" // {
      type = with lib.types; nullOr bool;
      default = null;
    };
    fqdn = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
}
