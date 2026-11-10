{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.allotment-changes;
  syncs = config.o11n.allotment-sync;

  follow = pkgs.writeShellApplication {
    name = "allotment-changes";
    runtimeInputs = [ pkgs.inotify-tools ];
    text = ''
      id=''${SSH_ORIGINAL_COMMAND:-}
      for may in "$@"; do
        if [[ $may == "$id" ]]; then
          case $id in
          ${lib.concatStrings (
            lib.mapAttrsToList (
              id: sync:
              lib.optionalString (sync.changes != null) ''
                ${lib.escapeShellArg id}) changes=${lib.escapeShellArg sync.changes} ;;
              ''
            ) syncs
          )}
          esac
          echo changed
          exec inotifywait -mq -e close_write --format changed "$changes"
        fi
      done
      echo "allotment-changes: this key follows $*, and not '$id'" >&2
      exit 1
    '';
  };

  follower = {
    options = {
      key = lib.mkOption {
        description = "the public key it logs in with";
        type = lib.types.str;
      };
      from = lib.mkOption {
        description = "the addresses it logs in from, as CIDRs";
        type = with lib.types; listOf str;
      };
      ids = lib.mkOption {
        description = "the allotments it follows, by the id `o11n.allotment-sync` has each by, which records its changes";
        type = with lib.types; listOf str;
      };
    };
  };
in
{
  options.o11n.allotment-changes = lib.mkOption {
    description = "the clients that follow what the replicas of the host's allotments change, logging in as allotment-changes, which says `changed` as one connects and as what its allotment's replicas change, and does nothing else";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule follower);
  };

  config = lib.mkIf (cfg != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        client: follower:
        map (id: {
          assertion = (syncs.${id}.changes or null) != null;
          message = "o11n.allotment-changes.${client} follows ${id}, which o11n.allotment-sync records no changes of.";
        }) follower.ids
      ) cfg
    );

    users.users.allotment-changes = {
      isSystemUser = true;
      group = "allotment-changes";
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = lib.mapAttrsToList (
        _: follower:
        ''from="${lib.concatStringsSep "," follower.from}",restrict,command="${lib.getExe follow} ${lib.concatStringsSep " " follower.ids}" ${follower.key}''
      ) cfg;
    };
    users.groups.allotment-changes = { };
  };
}
