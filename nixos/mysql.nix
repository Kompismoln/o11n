{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.o11n.mysql;
  inherit (config.services.mysql) package;
in
{
  imports = [
    ./dump.nix
    ./preserve-paths.nix
  ];

  options.o11n.mysql = {
    databases = lib.mkOption {
      description = "databases to manage";
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                default = name;
              };
              user = lib.mkOption {
                type = lib.types.str;
                default = config.name;
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.databases != { }) {
    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      dataDir = config.o11n.preserve.onDatabase "/var/lib/mysql";
    };

    o11n.dumps = lib.mapAttrs' (
      _: db:
      lib.nameValuePair "${db.name}-mysql" {
        database = db.name;
        inherit (db) user;
        command = "${package}/bin/mariadb-dump --single-transaction ${lib.escapeShellArg db.name}";
        after = [ "mysql.service" ];
      }
    ) cfg.databases;
  };
}
