# nixos/preserve-paths.nix
{
  config,
  lib,
  ...
}:

let
  cfg = config.o11n.preserve;

  under = root: path: if cfg.enable then root + path else path;
in
{
  options.o11n.preserve = {
    enable = lib.mkEnableOption "ephemeral root on this host";
    storage = lib.mkOption {
      description = "permanent storage";
      type = lib.types.str;
      default = "/srv/storage";
    };
    database = lib.mkOption {
      description = "permanent no-cow storage";
      type = lib.types.str;
      default = "/srv/database";
    };
    onStorage = lib.mkOption {
      description = "where a path's data lives: under storage on a host that preserves, otherwise at the path";
      type = with lib.types; functionTo str;
      readOnly = true;
      default = under cfg.storage;
    };
    onDatabase = lib.mkOption {
      description = "where a path's data lives: under database on a host that preserves, otherwise at the path";
      type = with lib.types; functionTo str;
      readOnly = true;
      default = under cfg.database;
    };
  };
}
