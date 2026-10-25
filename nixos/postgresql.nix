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
  inherit (config.services.postgresql) package dataDir;
  walDir = lib.mapNullable (wal: "${wal}/${package.psqlSchema}") config.o11n.preserve.postgresqlWal;
in
{
  imports = [
    ./dump.nix
    ./preserve-paths.nix
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
    containers = lib.mkOption {
      description = "containers that use the host's postgresql, to start after it and restart with it";
      default = [ ];
      type = with lib.types; listOf str;
    };
  };

  config = lib.mkIf (cfg.databases != { }) (
    lib.mkMerge [
      {
        services.postgresql = {
          enable = true;
          package = pkgs."postgresql_${org.postgres}";
          dataDir = config.o11n.preserve.onDatabase "/var/lib/postgresql/${package.psqlSchema}";
          extensions =
            ps: with ps; [
              postgis
              pg_repack
            ];
        };

        # Upstream creates only the default data directory.
        systemd.tmpfiles.rules = [ "d ${dataDir} 0700 postgres postgres - -" ];

        # Requires restarts a container when postgresql restarts, crashes included, and stops
        # it when postgresql stops; being wanted by postgresql brings it back when that starts.
        systemd.services = lib.genAttrs' cfg.containers (
          name:
          lib.nameValuePair "container@${name}" {
            after = [ "postgresql.service" ];
            requires = [ "postgresql.service" ];
            wantedBy = [ "postgresql.service" ];
          }
        );

        o11n.dumps = lib.mapAttrs' (
          _: db:
          lib.nameValuePair "${db.name}-pgsql" {
            database = db.name;
            inherit (db) user;
            command = "${package}/bin/pg_dump ${lib.escapeShellArg db.name}";
            after = [ "postgresql.target" ];
          }
        ) cfg.databases;
      }

      (lib.mkIf (walDir != null) {
        services.postgresql.initdbArgs = [ "--waldir=${walDir}" ];
        systemd.tmpfiles.rules = [ "d ${walDir} 0700 postgres postgres - -" ];
        systemd.services.postgresql = {
          unitConfig.RequiresMountsFor = [ walDir ];
          serviceConfig.ReadWritePaths = [ walDir ];
          # A cluster made before the WAL got its own volume moves it there once. A start
          # interrupted midway finishes the move, and nothing links a pg_wal that went missing.
          # The unit's syscall filter allows no chown, so cp keeps no ownership: it copies as
          # postgres, the files' owner.
          preStart = lib.mkAfter ''
            pgWal="$PGDATA/pg_wal"
            if [ ! -L "$pgWal" ]; then
              if [ -d "$pgWal" ]; then
                cp -R --preserve=mode,timestamps "$pgWal/." ${walDir}/
                sync -f ${walDir}
                mv "$pgWal" "$pgWal.moved"
              fi
              if [ -d "$pgWal.moved" ]; then
                ln -s ${walDir} "$pgWal"
              fi
            fi
            if [ -L "$pgWal" ]; then
              rm -rf "$pgWal.moved"
            fi
          '';
        };
      })
    ]
  );
}
