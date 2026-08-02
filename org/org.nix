# org/org.nix
{
  lib,
  config,
  context,
  ...
}:
let
  mailserverModule = lib.types.submoduleWith {
    modules = [ ./mailserver.nix ];
    specialArgs = {
      inherit context;
    };
  };
  themeModule = lib.types.submoduleWith {
    modules = [ ./theme.nix ];
    specialArgs = {
      inherit context;
    };
  };
  roleModule = lib.types.submoduleWith {
    modules = [ ./role.nix ];
    specialArgs = {
      inherit context;
    };
  };
  vpnModule = lib.types.submoduleWith {
    modules = [ ./vpn.nix ];
    specialArgs = {
      inherit context;
    };
  };
in
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "org";
  };

  options = {
    endpoint = lib.mkOption {
      description = "canonical name on internet";
      type = lib.types.str;
    };
    contact = lib.mkOption {
      description = "contact";
      default = "info@${config.endpoint}";
      type = lib.types.str;
    };
    timezone = lib.mkOption {
      description = "timezone";
      example = "Europe/Stockholm";
      type = lib.types.str;
    };
    locale = lib.mkOption {
      description = "default locale";
      type = lib.types.str;
      example = "en_US.UTF-8";
    };
    repo = lib.mkOption {
      description = "path to org source repo";
      type = lib.types.str;
    };
    storePath = lib.mkOption {
      description = "nix store path to org as a package";
      type = lib.types.path;
      default = context.path;
    };
    prefix = lib.mkOption {
      description = "ipv6 private prefix";
      type = context.types.globalPrefix6;
      example = "fda1:b2c3:d4e5";
    };
    prefixLength = lib.mkOption {
      description = "ipv6 private prefix length";
      type = lib.types.int;
      default = 64;
    };
    prefix4 = lib.mkOption {
      description = "ipv4 private prefix";
      type = context.types.globalPrefix4;
      example = "10.0";
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 private prefix length";
      type = lib.types.int;
      default = 24;
    };
    loPrefix = lib.mkOption {
      description = "ULA reserved for host-local service addresses on lo";
      type = context.types.subnetPrefix6;
      default = "${config.prefix}:ffff";
    };
    loCidr = lib.mkOption {
      description = "CIDR route of loPrefix";
      type = context.types.subnetCidr6;
      default = "${config.loPrefix}::/${toString config.prefixLength}";
    };
    mailserver = lib.mkOption {
      description = "main mailserver";
      default = null;
      type = lib.types.nullOr mailserverModule;
    };
    theme = lib.mkOption {
      description = "colors, wallpaper and fonts";
      default = null;
      type = lib.types.nullOr themeModule;
    };
    role = lib.mkOption {
      description = "role declaration";
      default = { };
      type = lib.types.attrsOf roleModule;
    };
    vpn = lib.mkOption {
      description = "attrset of vpn configurations";
      default = { };
      type = lib.types.attrsOf vpnModule;
    };
  };
}
