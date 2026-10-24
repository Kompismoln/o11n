{
  lib,
  evalNixosModule,
}:
let
  org = {
    postgres = "17";
    app = {
      # Sorts before chat and dumps the same database, but on another host.
      beta = {
        database = "chat";
        run-on-hosts = [ "dev" ];
        dump = "hourly";
      };
      blog = {
        database = "blog";
        run-on-hosts = [ "web" ];
        dump = null;
      };
      chat = {
        database = "chat";
        run-on-hosts = [ "web" ];
        dump = "daily";
      };
    };
  };

  appUser = name: {
    users.${name} = {
      isSystemUser = true;
      group = name;
      home = "/var/lib/${name}";
    };
    groups.${name} = { };
  };

  eval =
    databases:
    evalNixosModule [
      ../../nixos/postgresql.nix
      ../../nixos/mysql.nix
      {
        _module.args = {
          inherit org;
          host.name = "web";
        };
        users = lib.mkMerge [
          (appUser "blog")
          (appUser "chat")
        ];
        system.stateVersion = lib.trivial.release;
      }
      databases
    ];

  cfg = eval {
    o11n.postgresql.databases.chat = { };
    o11n.mysql.databases.blog = { };
  };

  collidingCfg = eval {
    o11n.postgresql.databases.chat = { };
    o11n.mysql.databases.chat = { };
  };

  preservingCfg = eval {
    o11n.postgresql.databases.chat = { };
    o11n.mysql.databases.blog = { };
    o11n.preserve = {
      enable = true;
      postgresqlWal = "/srv/wal";
    };
  };

  dataDirs = cfg: {
    postgresql = cfg.services.postgresql.dataDir;
    mysql = cfg.services.mysql.dataDir;
  };

  dumps = attrs: lib.filterAttrs (name: _: lib.hasSuffix "-dump" name) attrs;
  assertion =
    cfg: (lib.findFirst (a: lib.hasPrefix "o11n.dumps:" a.message) null cfg.assertions).assertion;
in
{
  test_dump_services = {
    expr = lib.attrNames (dumps cfg.systemd.services);
    expected = [
      "blog-mysql-dump"
      "chat-pgsql-dump"
    ];
  };

  test_dump_timers_from_org = {
    expr = lib.mapAttrs (_: timer: timer.timerConfig.OnCalendar) (dumps cfg.systemd.timers);
    expected = {
      chat-pgsql-dump = "daily";
    };
  };

  test_dump_runs_as_owner = {
    expr = cfg.systemd.services.chat-pgsql-dump.serviceConfig.User;
    expected = "chat";
  };

  test_dump_path_in_owner_home = {
    expr = cfg.o11n.dumps.chat-pgsql.path;
    expected = "/var/lib/chat/dbdump.sql";
  };

  test_dump_postgres_from_org = {
    expr = lib.versions.major cfg.services.postgresql.package.version;
    expected = "17";
  };

  test_dump_pg_dump_matches_server = {
    expr = cfg.o11n.dumps.chat-pgsql.command;
    expected = "${cfg.services.postgresql.package}/bin/pg_dump chat";
  };

  test_dump_paths_unique = {
    expr = map assertion [
      cfg
      collidingCfg
    ];
    expected = [
      true
      false
    ];
  };

  test_data_dirs = {
    expr = dataDirs cfg;
    expected = {
      postgresql = "/var/lib/postgresql/17";
      mysql = "/var/lib/mysql";
    };
  };

  test_data_dirs_on_database = {
    expr = dataDirs preservingCfg;
    expected = {
      postgresql = "/srv/database/var/lib/postgresql/17";
      mysql = "/srv/database/var/lib/mysql";
    };
  };

  test_postgresql_data_dir_created = {
    expr = lib.elem "d /srv/database/var/lib/postgresql/17 0700 postgres postgres - -" preservingCfg.systemd.tmpfiles.rules;
    expected = true;
  };

  test_postgresql_wal = {
    expr = {
      inherit (preservingCfg.services.postgresql) initdbArgs;
      inherit (preservingCfg.systemd.services.postgresql.serviceConfig) ReadWritePaths;
      created = lib.elem "d /srv/wal/17 0700 postgres postgres - -" preservingCfg.systemd.tmpfiles.rules;
    };
    expected = {
      initdbArgs = [ "--waldir=/srv/wal/17" ];
      ReadWritePaths = [
        "/srv/database/var/lib/postgresql/17"
        "/srv/wal/17"
      ];
      created = true;
    };
  };

  test_postgresql_wal_with_data = {
    expr = cfg.services.postgresql.initdbArgs;
    expected = [ ];
  };
}
