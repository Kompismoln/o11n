# lib/context.nix
{
  config,
  lib,
  ...
}:
let
  types = (import ./types.nix) lib;
  inventoryFromV1 = import ../org/spec-v1/mkInventory.nix;
in
{
  config = {
  };

  options = {
    path = lib.mkOption {
      description = "path";
      type = lib.types.path;
      default = config.flake.outPath;
    };
    flake = lib.mkOption {
      description = "flake";
      type = types.flake;
      default = builtins.getFlake (toString config.path);
    };
    inputs = lib.mkOption {
      description = "inputs";
      type = lib.types.attrsOf types.flake;
      default = config.flake.inputs // {
        self = config.flake;
      };
    };
    types = lib.mkOption {
      description = "org types";
      type = lib.types.attrsOf lib.types.anything;
      default = types // (import ../org/types.nix lib config);
    };
    classes = lib.mkOption {
      description = "org types";
      type = lib.types.attrsOf lib.types.anything;
      default = import ../org/classes.nix;
    };
    raw = lib.mkOption {
      description = "unparsed org";
      type = types.raw;
      default = lib.importTOML (config.path + "/org.toml");
    };
    spec-v1 = lib.mkOption {
      description = "spec-v1";
      type = lib.types.submoduleWith {
        modules = [ ../org/spec-v1 ];
        specialArgs.context = config;
      };
      default = config.raw;
    };
    inventory = lib.mkOption {
      description = "inventory";
      default = inventoryFromV1 {
        context = config;
        inherit lib;
      };
      type = lib.types.submoduleWith {
        modules = [ ../org/inventory.nix ];
        specialArgs.context = config;
      };
    };
  };
}
