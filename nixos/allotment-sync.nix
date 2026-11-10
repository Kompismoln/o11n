{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.allotment-sync;

  device = {
    options = {
      id = lib.mkOption {
        description = "the device's ID";
        type = lib.types.str;
      };
      name = lib.mkOption {
        description = "the device's name";
        type = lib.types.str;
      };
      addresses = lib.mkOption {
        description = "where to dial the device, or none to wait for it to dial";
        type = with lib.types; listOf str;
        default = [ ];
      };
    };
  };

  sync = {
    options = {
      folder = lib.mkOption {
        description = "the folder synced";
        type = lib.types.str;
      };
      state = lib.mkOption {
        description = "Syncthing's home, its configuration, the links to the device's certificate and key, and its database, in a directory the user can make it in";
        type = lib.types.str;
      };
      user = lib.mkOption {
        description = "the user Syncthing runs as";
        type = lib.types.str;
      };
      group = lib.mkOption {
        description = "the group Syncthing runs as";
        type = lib.types.str;
      };
      secret = lib.mkOption {
        description = "the file with the device's certificate and key";
        type = lib.types.str;
      };
      listen = lib.mkOption {
        description = "the addresses Syncthing listens on, or none to only dial";
        type = with lib.types; listOf str;
        default = [ ];
      };
      self = lib.mkOption {
        description = "this device";
        type = lib.types.submodule device;
      };
      peers = lib.mkOption {
        description = "the devices the folder is synced with";
        type = with lib.types; listOf (submodule device);
      };
      after = lib.mkOption {
        description = "the units Syncthing requires and starts after";
        type = with lib.types; listOf str;
        default = [ ];
      };
      wants = lib.mkOption {
        description = "the units Syncthing wants and starts after, as those that bring up the addresses it listens on";
        type = with lib.types; listOf str;
        default = [ ];
      };
      changes = lib.mkOption {
        description = "a file rewritten as Syncthing finishes each batch of what its peers change in the folder, or null";
        type = with lib.types; nullOr str;
        default = null;
      };
      desktop = lib.mkOption {
        description = "a link to the folder on its user's Desktop, with a badge of how it syncs, or null";
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                description = "the link's name";
                type = lib.types.str;
              };
              icon = lib.mkOption {
                description = "the link's icon, or null for the folder's";
                type = with lib.types; nullOr path;
                default = null;
              };
            };
          }
        );
        default = null;
      };
    };
  };

  xml = lib.escapeXML;

  socket = sync: "${sync.state}/api.sock";

  # Policy: the API is on a socket in Syncthing's home, which only its user and root reach, so its key, in the store, guards
  # nothing more.
  apiKey = id: "allotment-sync-${id}";

  deviceXml = device: ''
    <device id="${xml device.id}" name="${xml device.name}" compression="metadata" introducer="false">
    ${
      lib.concatMapStrings (address: "  <address>${xml address}</address>\n") (
        if device.addresses == [ ] then [ "dynamic" ] else device.addresses
      )
    }</device>
  '';

  # Policy: Syncthing knows nothing but what's here, and finds the other devices by their addresses alone.
  configXml =
    id: sync:
    pkgs.writeText "allotment-sync-${id}.xml" ''
      <configuration version="52">
      <folder id="${xml id}" label="${xml id}" path="${xml sync.folder}" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="10" ignorePerms="false" autoNormalize="true">
      ${
        lib.concatMapStrings (device: "  <device id=\"${xml device.id}\"></device>\n") (
          [ sync.self ] ++ sync.peers
        )
      }  <markerName>.stfolder</markerName>
      </folder>
      ${lib.concatMapStrings deviceXml ([ sync.self ] ++ sync.peers)}<gui enabled="true" tls="false">
        <address>${xml (socket sync)}</address>
        <apikey>${xml (apiKey id)}</apikey>
      </gui>
      <options>
      ${
        lib.concatMapStrings (address: "  <listenAddress>${xml address}</listenAddress>\n") (
          if sync.listen == [ ] then [ "tcp://127.0.0.1:0" ] else sync.listen
        )
      }  <globalAnnounceEnabled>false</globalAnnounceEnabled>
        <localAnnounceEnabled>false</localAnnounceEnabled>
        <relaysEnabled>false</relaysEnabled>
        <natEnabled>false</natEnabled>
        <startBrowser>false</startBrowser>
        <urAccepted>-1</urAccepted>
        <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
        <crashReportingEnabled>false</crashReportingEnabled>
        <announceLANAddresses>false</announceLANAddresses>
      </options>
      </configuration>
    '';

  unit = id: sync: {
    description = "Syncthing for the allotment ${id}";
    wantedBy = [ "multi-user.target" ];
    requires = sync.after;
    inherit (sync) wants;
    after = sync.after ++ sync.wants;
    unitConfig.RequiresMountsFor = [
      sync.folder
      sync.state
    ];
    environment = {
      HOME = sync.state;
      STNODEFAULTFOLDER = "1";
    };
    serviceConfig = {
      User = sync.user;
      Group = sync.group;
      UMask = "0077";
      ExecStartPre = pkgs.writeShellScript "allotment-sync-${id}-start" ''
        set -euo pipefail
        mkdir -p ${lib.escapeShellArg sync.folder} ${lib.escapeShellArg sync.state}
        rm -f ${lib.escapeShellArg (socket sync)}
        install -m 0600 ${configXml id sync} ${lib.escapeShellArg "${sync.state}/config.xml"}
        ln -sfn ${lib.escapeShellArg sync.secret} ${lib.escapeShellArg "${sync.state}/cert.pem"}
        ln -sfn ${lib.escapeShellArg sync.secret} ${lib.escapeShellArg "${sync.state}/key.pem"}
      '';
      ExecStart = "${lib.getExe pkgs.syncthing} serve --home=${lib.escapeShellArg sync.state} --no-browser --no-restart";
      Restart = "on-failure";
      RestartSec = 10;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "full";
    };
  };

  # Dependency: crates/o11n/src/allotments.rs reads what this says, as JSON: for each allotment, or the one its argument
  # names, the folder's state, its errors, its conflicting copies, and for each peer whether it's connected, when it was
  # last seen, and how much of the folder it has; or else the error that kept it from saying.
  status = pkgs.writeShellApplication {
    name = "allotment-sync-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.jq
    ];
    text = ''
      said='{}'
      ${lib.concatStrings (
        lib.mapAttrsToList (id: sync: ''
          if [[ -z ''${1:-} || $1 == ${lib.escapeShellArg id} ]]; then
          api() {
            curl -sS --fail-with-body --max-time 10 --unix-socket ${lib.escapeShellArg (socket sync)} \
              -H ${lib.escapeShellArg "X-API-Key: ${apiKey id}"} "http://localhost/rest/$1"
          }
          if status=$(api ${lib.escapeShellArg "db/status?folder=${id}"} 2>&1); then
            errors=$(api ${lib.escapeShellArg "folder/errors?folder=${id}"})
            connections=$(api system/connections)
            stats=$(api stats/device)
            conflicts=$(find ${lib.escapeShellArg sync.folder} -name '*.sync-conflict-*' 2>/dev/null | wc -l)
            peers='{}'
            ${lib.concatMapStrings (peer: ''
              completion=$(api ${lib.escapeShellArg "db/completion?folder=${id}&device=${peer.id}"})
              seen=$(jq -r --arg id ${lib.escapeShellArg peer.id} '.[$id].lastSeen // "1970-01-01T00:00:00Z"' <<<"$stats")
              peers=$(jq --arg name ${lib.escapeShellArg peer.name} --arg id ${lib.escapeShellArg peer.id} \
                --arg seen "$seen" --argjson ago "$(($(date +%s) - $(date -d "$seen" +%s)))" \
                --argjson connections "$connections" --argjson completion "$completion" \
                '.[$name] = {
                  connected: ($connections.connections[$id].connected // false),
                  lastSeen: $seen,
                  lastSeenAgoS: $ago,
                  completion: $completion.completion,
                  needItems: $completion.needItems,
                  needBytes: $completion.needBytes
                }' <<<"$peers")
            '') sync.peers}
            said=$(jq --arg id ${lib.escapeShellArg id} --argjson status "$status" --argjson errors "$errors" \
              --argjson conflicts "$conflicts" --argjson peers "$peers" \
              '.[$id] = {
                state: $status.state,
                errors: ([$status.error // empty | select(. != "")] + [($errors.errors // [])[] | "\(.path): \(.error)"]),
                conflicts: $conflicts,
                peers: $peers
              }' <<<"$said")
          else
            said=$(jq --arg id ${lib.escapeShellArg id} --arg error "$status" '.[$id] = { error: $error }' <<<"$said")
          fi
          fi
        '') cfg
      )}
      echo "$said"
    '';
  };

  # Policy: it follows ItemFinished alone, which Syncthing has as it applies a peer's change, and not
  # LocalChangeDetected, which another writer to the folder makes.
  changesUnit = id: sync: {
    description = "the record of what the peers of the allotment ${id} change in it";
    wantedBy = [ "allotment-sync@${id}.service" ];
    bindsTo = [ "allotment-sync@${id}.service" ];
    after = [ "allotment-sync@${id}.service" ];
    path = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    serviceConfig = {
      User = sync.user;
      Group = sync.group;
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      since=0
      while true; do
        events=$(curl -sS --fail-with-body --max-time 90 --unix-socket ${lib.escapeShellArg (socket sync)} \
          -H ${lib.escapeShellArg "X-API-Key: ${apiKey id}"} \
          "http://localhost/rest/events?events=ItemFinished&timeout=60&since=$since")
        since=$(jq --argjson since "$since" '.[-1].id // $since' <<<"$events")
        if jq -e --arg folder ${lib.escapeShellArg id} 'any(.data.folder == $folder and .data.error == null)' \
          <<<"$events" >/dev/null; then
          date +%s.%N >${lib.escapeShellArg sync.changes}
        fi
      done
    '';
  };

  # Policy: the link is made where nothing is, and else left as it is; its badge is one of the icon theme's emblems:
  # synced, syncing, offline, or an error or a conflicting copy.
  desktopUnit =
    id: sync:
    let
      link = "$HOME/Desktop/${sync.desktop.name}";
    in
    {
      description = "the desktop link to the allotment ${id}, and its badge of how it syncs";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = sync.user;
      path = [
        pkgs.coreutils
        pkgs.glib
        pkgs.jq
        status
      ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 10;
      };
      script = ''
        link="${link}"
        mkdir -p "$HOME/Desktop"
        if [[ ! -e $link && ! -L $link ]]; then
          ln -s ${lib.escapeShellArg sync.folder} "$link"
        fi
        ${lib.optionalString (sync.desktop.icon != null) ''
          gio set -n "$link" metadata::custom-icon ${lib.escapeShellArg "file://${sync.desktop.icon}"}
        ''}
        shown=
        while true; do
          badge=$(allotment-sync-status ${lib.escapeShellArg id} | jq -r --arg id ${lib.escapeShellArg id} '.[$id]
            | if .error or (.errors | length > 0) or .conflicts > 0 then "emblem-important"
              elif (.peers | all(.connected) | not) then "emblem-unreadable"
              elif .state != "idle" or (.peers | any(.completion < 100)) then "emblem-synchronizing"
              else "emblem-default" end')
          if [[ $badge != "$shown" ]]; then
            gio set -n -t stringv "$link" metadata::emblems "$badge"
            # Accommodating for Nemo, which redraws an icon as the file changes, and not as its metadata does.
            touch -h "$link"
            shown=$badge
          fi
          sleep 5
        done
      '';
    };
in
{
  options.o11n.allotment-sync = lib.mkOption {
    description = "each allotment the host syncs, by its id, which allotment-sync@<id> runs Syncthing for";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule sync);
  };

  config = lib.mkIf (cfg != { }) {
    environment.systemPackages = [ status ];

    systemd.services =
      lib.mapAttrs' (id: sync: lib.nameValuePair "allotment-sync@${id}" (unit id sync)) cfg
      // lib.mapAttrs' (id: sync: lib.nameValuePair "allotment-changes@${id}" (changesUnit id sync)) (
        lib.filterAttrs (_: sync: sync.changes != null) cfg
      );

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _: sync: "f '${sync.changes}' 0644 ${sync.user} ${sync.group} - -"
    ) (lib.filterAttrs (_: sync: sync.changes != null) cfg);

    systemd.user.services = lib.mapAttrs' (
      id: sync: lib.nameValuePair "allotment-desktop@${id}" (desktopUnit id sync)
    ) (lib.filterAttrs (_: sync: sync.desktop != null) cfg);
  };
}
