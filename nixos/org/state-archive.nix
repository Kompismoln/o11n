# nixos/org/state-archive.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  # Dependency: nixos/services/archive.nix serves at this port.
  port = 8000;

  archives = entity: if entity.principal.state == null then { } else entity.principal.state.archives;
  archiving = lib.filter (entity: archives entity != { }) host.principals;

  # Dependency: nixos/services/archive.nix serves at the archive service's address on its vpn.
  server =
    name:
    let
      inherit (org.service.archive) vpn;
    in
    {
      inherit vpn;
      inherit (org.host.${name}.network.${vpn}.principals.service-archive) fqdn;
      cert = org.certs.${org.vpn.${vpn}.namespace}.publicKeys.tls-cert;
    };

  archive = pkgs.writeShellApplication {
    name = "state-archive";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.restic
      pkgs.util-linux
    ];
    text = ''
      systemctl start "state-snapshot@$ID.service"
      # Policy: the lock keeps the snapshot from being replaced while it's read; one taken between the start and the
      # lock is as good.
      exec 9>"/run/o11n/state/$ID.lock"
      flock 9

      # Policy: the snapshot is archived as the home it was taken of, which the unit's own mounts alone see.
      mount --bind -o ro "$(readlink -f "/run/o11n/state/$ID")" "$STATE_HOME"

      # Policy: a .resticignore reads as a .gitignore, wherever it is: a pattern with a slash but at its end is
      # anchored to the file's directory, one without matches at any depth below it, and the deeper file wins.
      excludes=$(mktemp)
      find "$STATE_HOME" -name .resticignore -type f -printf '%d\t%p\n' | sort -n | cut -f2- |
        while IFS= read -r file; do
          dir=$(dirname "$file")
          while IFS= read -r line || [[ -n $line ]]; do
            [[ -n $line && $line != \#* ]] || continue
            negation=""
            if [[ $line == '!'* ]]; then
              negation='!'
              line=''${line:1}
            fi
            line=''${line%/}
            if [[ $line == */* ]]; then
              echo "$negation$dir/''${line#/}"
            else
              echo "$negation$dir/**/$line"
            fi
          done <"$file"
        done >"$excludes"

      RESTIC_REST_PASSWORD=$(<"$ARCHIVE_PASSWD_FILE")
      export RESTIC_REST_PASSWORD
      restic cat config >/dev/null 2>&1 || restic init
      restic backup --exclude-file "$excludes" "$STATE_HOME"
    '';
  };

  unitName = entity: archiveHost: "state-archive@${entity.handle}:${archiveHost}";
in
{
  imports = [ ./mail.nix ];

  config = lib.mkIf (archiving != [ ]) {
    o11n.mail.failures = lib.listToAttrs (
      lib.concatMap (
        entity:
        map (name: lib.nameValuePair (unitName entity name) entity.handle) (lib.attrNames (archives entity))
      ) archiving
    );

    assertions = lib.concatMap (
      entity:
      let
        id = entity.handle;
      in
      [
        {
          assertion = builtins.pathExists (entity.publicKeys.archive-passwd or "/nonexistent");
          message = "${id} archives without an archive-passwd: run `o11n secret generate ${id} archive-passwd` and `o11n secret generate ${id} restic-key`.";
        }
      ]
      ++ lib.concatMap (
        name:
        let
          archiveHost = org.host.${name} or null;
        in
        [
          {
            assertion =
              archiveHost != null && lib.any (service: service.name == "archive") archiveHost.services;
            message = "${id} archives to ${name}, which is no host with the archive service: fix principal.state.archives.";
          }
          {
            assertion = (org.service.archive.vpn or null) == null || lib.elem org.service.archive.vpn host.vpns;
            message = "${id} archives to ${name} on ${
              toString (org.service.archive.vpn or null)
            }, which ${host.name} isn't on: fix principal.state.archives or ${host.name}'s vpns.";
          }
        ]
      ) (lib.attrNames (archives entity))
    ) archiving;

    sops.secrets = lib.listToAttrs (
      lib.concatMap (
        entity:
        map
          (
            key:
            lib.nameValuePair "${entity.name}/${key}" {
              inherit (entity.secrets) sopsFile;
            }
          )
          [
            "archive-passwd"
            "restic-key"
          ]
      ) archiving
    );

    systemd.services = lib.listToAttrs (
      lib.concatMap (
        entity:
        lib.mapAttrsToList (
          name: _:
          lib.nameValuePair (unitName entity name) {
            description = "archive ${entity.handle}'s state to ${name}";
            environment = {
              ID = entity.handle;
              STATE_HOME = entity.principal.home;
              ARCHIVE_PASSWD_FILE = config.sops.secrets."${entity.name}/archive-passwd".path;
              RESTIC_PASSWORD_FILE = config.sops.secrets."${entity.name}/restic-key".path;
              RESTIC_REPOSITORY = "rest:https://${(server name).fqdn}:${toString port}/${entity.handle}/";
              RESTIC_REST_USERNAME = entity.handle;
              RESTIC_CACERT = toString (server name).cert;
              RESTIC_CACHE_DIR = "/var/cache/restic";
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe archive;
              PrivateMounts = true;
              CacheDirectory = "restic";
            };
          }
        ) (archives entity)
      ) archiving
    );

    systemd.timers = lib.listToAttrs (
      lib.concatMap (
        entity:
        lib.mapAttrsToList (
          name: archive:
          lib.nameValuePair (unitName entity name) {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = archive.schedule;
              Persistent = true;
            };
          }
        ) (lib.filterAttrs (_: archive: archive.schedule != null) (archives entity))
      ) archiving
    );
  };
}
