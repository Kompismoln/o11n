{
  config,
  context,
  lib,
  ...
}:
let
  counts = [
    "keep-last"
    "keep-hourly"
    "keep-daily"
    "keep-weekly"
    "keep-monthly"
    "keep-yearly"
  ];
  durations = [
    "keep-within"
    "keep-within-hourly"
    "keep-within-daily"
    "keep-within-weekly"
    "keep-within-monthly"
    "keep-within-yearly"
  ];

  prune =
    { config, ... }:
    {
      options =
        lib.genAttrs counts (
          name:
          lib.mkOption {
            description = "restic forget's --${name}: the number of snapshots to keep, -1 for all";
            default = null;
            type = with lib.types; nullOr (ints.between (-1) 2147483647);
          }
        )
        // lib.genAttrs durations (
          name:
          lib.mkOption {
            description = "restic forget's --${name}: a duration such as 1y2m3d4h, before the latest snapshot";
            default = null;
            type = with lib.types; nullOr (strMatching "([0-9]+[ymdh])+");
          }
        )
        // {
          keep-tag = lib.mkOption {
            description = "restic forget's --keep-tag: the tags whose snapshots to keep";
            default = [ ];
            type = with lib.types; listOf str;
          };
          flags = lib.mkOption {
            description = "the rules as restic forget's flags, which crates/o11n/src/state.rs passes it";
            internal = true;
            readOnly = true;
            default = lib.cli.toCommandLineGNU { } (
              lib.filterAttrs (_: rule: rule != null && rule != [ ]) (
                lib.getAttrs (counts ++ durations ++ [ "keep-tag" ]) config
              )
            );
          };
        };
    };
in
{
  options = {
    preserve = lib.mkOption {
      description = "whether the principal's home outlasts a boot on a host whose root doesn't, which archiving it takes";
      default = true;
      type = lib.types.bool;
    };
    archives = lib.mkOption {
      description = "the hosts with the archive service that archive the principal's home, as a list or each with a schedule and a prune; only an archive with a schedule has a timer";
      default = { };
      type =
        with lib.types;
        coercedTo (listOf context.types.host.ref) (hosts: lib.genAttrs hosts (_: { })) (
          attrsOf (submodule {
            options = {
              schedule = lib.mkOption {
                description = "when to archive, as a systemd calendar event, or null to archive only when asked";
                default = null;
                type = nullOr str;
              };
              prune = lib.mkOption {
                description = "what of the principal's archive on the host `o11n state prune` keeps, as restic forget's policy; with none, everything";
                default = { };
                type = submodule prune;
              };
            };
          })
        );
    };
    keys = lib.mkOption {
      description = "the keys the principal's entity has for its state";
      internal = true;
      readOnly = true;
      default = lib.optionalAttrs (config.archives != { }) {
        archive-passwd = "htpasswd";
        restic-key = "passphrase";
      };
    };
  };
}
