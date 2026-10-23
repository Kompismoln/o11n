# nixos/postgresql.nix
{
  config,
  lib,
  org,
  pkgs,
  ...
}:

let
  cfg = config.o11n.postgresql;
  inherit (config.services.postgresql) package;
in
{
  imports = [
    ./dump.nix
  ];

  options.o11n.postgresql = {
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
    o11n.preserve.databases = [
      {
        directory = "/var/lib/postgresql";
        user = "postgres";
        group = "postgres";
      }
    ];

    services.postgresql = {
      enable = true;
      package = pkgs."postgresql_${org.postgres}";
      extensions =
        ps: with ps; [
          postgis
          pg_repack
        ];
    };

    o11n.dumps = lib.mapAttrs' (
      _: db:
      lib.nameValuePair "${db.name}-pgsql" {
        database = db.name;
        inherit (db) user;
        command = "${package}/bin/pg_dump ${lib.escapeShellArg db.name}";
        after = [ "postgresql.target" ];
      }
    ) cfg.databases;
  };
}
