# lib/context.nix
{ config, lib, ... }:
let
  types = (import ./types.nix) lib;
in
{
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
    spec = lib.mkOption {
      description = "unparsed org";
      type = types.spec;
      default = lib.importTOML (config.path + "/org.toml");
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
    org = lib.mkOption {
      description = "org";
      type = lib.types.submodule {
        imports = [ ../org ];
        _module.args = {
          context = config;
        };
      };
      default = config.spec;
    };
  };
}
