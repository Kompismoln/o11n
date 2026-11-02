# nixos/dump.nix
{
  config,
  host,
  lib,
  ...
}:

let
  cfg = config.o11n.dumps;
  hostConfig = config;

  # Policy: a dump is part of its owner's snapshot, which the owner's archive takes.
  snapshotOf =
    user:
    map (id: "state-snapshot@${id}.service") (
      lib.filter (id: lib.removePrefix "${lib.head (lib.splitString "-" id)}-" id == user) host.principals
    );

  dumpOpts =
    { config, ... }:
    {
      options = {
        database = lib.mkOption {
          description = "database to dump";
          type = lib.types.str;
        };
        user = lib.mkOption {
          description = "user that owns the database and the dump";
          type = lib.types.str;
        };
        command = lib.mkOption {
          description = "command that writes the dump to stdout";
          type = lib.types.str;
        };
        after = lib.mkOption {
          description = "units the database server runs in";
          type = with lib.types; listOf str;
        };
        path = lib.mkOption {
          description = "where to keep the dump";
          type = lib.types.str;
          default = "${hostConfig.users.users.${config.user}.home}/dbdump.sql";
        };
      };
    };
in
{
  options.o11n.dumps = lib.mkOption {
    description = "database dumps, one unit each";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule dumpOpts);
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = lib.allUnique (lib.mapAttrsToList (_: dump: dump.path) cfg);
        message = "o11n.dumps: two dumps write to the same path";
      }
    ];

    systemd.services = lib.mapAttrs' (
      name: dump:
      lib.nameValuePair "${name}-dump" {
        description = "dump ${dump.database}";
        requires = dump.after;
        inherit (dump) after;
        before = snapshotOf dump.user;
        requiredBy = snapshotOf dump.user;
        script = ''
          umask 0077
          ${dump.command} > ${dump.path}.tmp
          mv ${dump.path}.tmp ${dump.path}
        '';
        serviceConfig = {
          Type = "oneshot";
          User = dump.user;
        };
      }
    ) cfg;
  };
}
