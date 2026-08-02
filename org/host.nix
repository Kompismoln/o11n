# org/host.nix
{
  lib,
  config,
  context,
  ...
}:
{
  imports = [
    ./entity.nix
  ];

  options = {
    rescueMode = lib.mkEnableOption "insecure rescue mode.";
    boot = lib.mkOption {
      type = lib.types.enum [
        "grub"
        "systemd"
      ];
      default = "systemd";
      description = "boot method";
    };
    configurationFile = lib.mkOption {
      type = lib.types.path;
      default = context.path + "/hosts/${config.name}/configuration.nix";
      description = "path to specific configuration";
    };
    facterFile = lib.mkOption {
      type = lib.types.path;
      default = context.path + "/hosts/${config.name}/facter.json";
      description = "facter report path";
    };
    luksKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/luks-key";
      description = "initrd luks key";
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "maybe canonical name on internet";
    };
    system = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "host platform";
    };
    stateVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "nixos state version";
    };
    desktop = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "attrset of desktop settings";
    };
    monitors = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      description = "list of monitors possibly connected to the host";
    };
    devices = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      description = "list of devices possibly connected to the host";
    };
  };
}
