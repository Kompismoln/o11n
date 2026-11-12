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
  port = toString config.services.postgresql.settings.port;

  # Fact: template0 takes no connections, so it can't be reindexed, and nothing creates a database from it.
  collations = "select datname, coalesce(datcollversion, '-'), coalesce(pg_database_collation_actual_version(oid), '-') from pg_database where datallowconn";

  # Dependency: crates/o11n/src/postgresql.rs reads this through switch-system databases, a line each:
  # <database> <collation version it was made with> <collation version postgresql has now>.
  collationStatus = pkgs.writeShellApplication {
    name = "postgresql-collation-status";
    runtimeInputs = [
      package
      pkgs.util-linux
    ];
    text = ''
      PGPORT=${port} runuser -u postgres -- psql -d postgres -AtqX -F ' ' -v ON_ERROR_STOP=1 -c ${lib.escapeShellArg collations}
    '';
  };
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
          # Policy: each database, and the role it's owned by, is made where it's missing, and owned by its role when
          # that has the database's name, as postgresql-setup does each time it starts.
          ensureDatabases = lib.mapAttrsToList (_: db: db.name) cfg.databases;
          ensureUsers = map (user: {
            name = user;
            ensureDBOwnership = lib.any (db: db.name == user && db.user == user) (lib.attrValues cfg.databases);
          }) (lib.unique (lib.mapAttrsToList (_: db: db.user) cfg.databases));
        };

        # Fact: upstream creates only the default data directory.
        systemd.tmpfiles.rules = [ "d ${dataDir} 0700 postgres postgres - -" ];

        # Fact: Requires restarts a container when postgresql restarts, crashes included, and stops it when postgresql
        # stops; being wanted by postgresql brings it back when that starts.
        systemd.services = lib.genAttrs' cfg.containers (
          name:
          lib.nameValuePair "container@${name}" {
            after = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            requires = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
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

      {
        # Policy: a database whose collation changed under it, as when glibc does, gets its indexes rebuilt, as text
        # sorts differently than when they were built; postgresql restarts with a new glibc, and this with it.
        systemd.services.postgresql-collation = {
          description = "Reindex databases whose collation version changed";
          requires = [ "postgresql-setup.service" ];
          after = [ "postgresql-setup.service" ];
          wantedBy = [ "postgresql.target" ];
          path = [ package ];
          environment.PGPORT = port;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
            Group = "postgres";
          };
          script = ''
            said=$(psql -d postgres -AtqX -F ' ' -v ON_ERROR_STOP=1 -c ${lib.escapeShellArg collations})
            while read -r database made now; do
              [[ -n $database && $made != "$now" ]] || continue
              echo "$database was made with collation version $made, and postgresql has $now: reindexing it"
              psql -d "$database" -qX -v ON_ERROR_STOP=1 -v database="$database" <<'EOF'
            REINDEX DATABASE :"database";
            ALTER DATABASE :"database" REFRESH COLLATION VERSION;
            EOF
            done <<<"$said"
          '';
        };

        environment.systemPackages = [ collationStatus ];
      }

      (lib.mkIf (walDir != null) {
        services.postgresql.initdbArgs = [ "--waldir=${walDir}" ];
        systemd.tmpfiles.rules = [ "d ${walDir} 0700 postgres postgres - -" ];
        systemd.services.postgresql = {
          unitConfig.RequiresMountsFor = [ walDir ];
          serviceConfig.ReadWritePaths = [ walDir ];
          # Policy: a cluster made before the WAL got its own volume moves it there once; a start interrupted midway
          # finishes the move, and nothing links a pg_wal that went missing.
          # Fact: the unit's syscall filter allows no chown, so cp keeps no ownership: it copies as postgres, the files'
          # owner.
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
