{ config, lib, ... }:
{
  options = {
    path = lib.mkOption {
      description = "path";
      type = lib.types.path;
      default = config.flake.outPath;
    };
    flake = lib.mkOption {
      description = "flake";
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = builtins.getFlake (toString config.path);
    };
    inputs = lib.mkOption {
      description = "inputs";
      type = lib.types.attrsOf (lib.types.lazyAttrsOf lib.types.raw);
      default = config.flake.inputs // {
        self = config.flake;
      };
    };
    spec = lib.mkOption {
      description = "unparsed org";
      type = lib.types.lazyAttrsOf lib.types.anything;
      default = lib.importTOML (config.path + "/org.toml");
    };
    types = lib.mkOption {
      description = "org types";
      type = lib.types.attrsOf lib.types.anything;
      default = import ./types.nix lib config;
    };
    classes = lib.mkOption {
      description = "entity classes";
      type = lib.types.attrsOf lib.types.anything;
      default = import ./classes.nix;
    };
    org = lib.mkOption {
      description = "org";
      type = lib.types.submodule {
        imports = [ ./. ];
        _module.args = {
          context = config;
        };
      };
      default = config.spec;
    };
  };
}
