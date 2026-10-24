# nixos/dump.nix
{
  config,
  host,
  lib,
  org,
  ...
}:

let
  cfg = config.o11n.dumps;
  hostConfig = config;

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
        startAt = lib.mkOption {
          description = "when to dump, as a systemd calendar event, or null for no timer";
          type = with lib.types; nullOr str;
          default =
            (lib.findFirst (app: app.database == config.database && lib.elem host.name app.run-on-hosts) {
              dump = null;
            } (lib.attrValues org.app)).dump;
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

    systemd.timers = lib.mapAttrs' (
      name: dump:
      lib.nameValuePair "${name}-dump" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = dump.startAt;
          Persistent = true;
        };
      }
    ) (lib.filterAttrs (_: dump: dump.startAt != null) cfg);
  };
}
