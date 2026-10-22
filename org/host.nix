{
  lib,
  config,
  context,
  ...
}:
let
  inherit (context) org;
in
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "host";
  };

  options = {
    configurationFile = lib.mkOption {
      description = "path to specific configuration";
      type = lib.types.path;
      default = context.path + "/hosts/${config.name}/configuration.nix";
    };
    boot = lib.mkOption {
      description = "boot method";
      type = lib.types.enum [
        "grub"
        "systemd"
      ];
      default = "systemd";
    };
    hardwareReport = lib.mkOption {
      description = "hardware report method";
      type = lib.types.enum [
        "standard"
        "facter"
      ];
      default = "facter";
    };
    facterFile = lib.mkOption {
      description = "facter report path";
      default = context.path + "/hosts/${config.name}/facter.json";
      type = lib.types.path;
    };
    luksKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/luks-key";
    };
    users = lib.mkOption {
      description = "users";
      type = lib.types.listOf context.types.user.ref;
    };
    roles = lib.mkOption {
      description = "roles that this host has";
      type = lib.types.listOf context.types.role.ref;
    };
    endpoint = lib.mkOption {
      description = "maybe canonical name on internet";
      default = null;
      type = with lib.types; nullOr str;
    };
    vpns = lib.mkOption {
      description = "list of interface names for vpns";
      type = lib.types.listOf context.types.vpn.ref;
    };
    system = lib.mkOption {
      description = "host platform";
      type = lib.types.str;
    };
    stateVersion = lib.mkOption {
      description = "nixos state version";
      type = with lib.types; nullOr str;
      default = null;
    };
    home = lib.mkOption {
      description = "list of home configurations for a user";
      default = { };
      type = lib.types.attrsOf (context.types.home.module config);
    };
    network = lib.mkOption {
      description = "networks to configure on host";
      default = { };
      type = lib.types.attrsOf context.types.network.module;
    };
    disk-layouts = lib.mkOption {
      description = "record of disk layouts that applies to host";
      default = { };
      type = lib.types.attrsOf context.types.disk.module;
    };
    desktop = lib.mkOption {
      description = "attrset of desktop settings";
      default = { };
      type = lib.types.attrsOf lib.types.anything;
    };
    monitors = lib.mkOption {
      description = "list of monitors possibly connected to the host";
      default = [ ];
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
    };
    devices = lib.mkOption {
      description = "list of devices possibly connected to the host";
      default = [ ];
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
    };
    rescueMode = lib.mkEnableOption "insecure rescue mode.";
  };
  config = {
    network =
      let
        mkAddress = host: vpn: "${vpn.prefix}::${host.ids.hex4}";
        mkAddress4 = host: vpn: "${vpn.prefix4}.${host.ids.str}";
      in
      lib.mapAttrs (
        _: vpn:
        lib.mkDefault {
          inherit (vpn) interface prefixLength prefixLength4;
          mode = null;
          dns = lib.concatMap (dnsHost: [
            (mkAddress org.host.${dnsHost} vpn)
            (mkAddress4 org.host.${dnsHost} vpn)
          ]) vpn.dns;
          address = mkAddress config vpn;
          destination = vpn.address;
          address4 = mkAddress4 config vpn;
          destination4 = vpn.address4;
          fqdn = "${config.name}.${vpn.namespace}";
        }
      ) org.vpn;
  };
}
