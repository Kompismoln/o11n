{
  app,
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:

let
  cfg = {
    inherit (app)
      name
      endpoint
      database
      ssl
      ;
    inherit (app.principal) bindAddress uid gid;
    home = "${app.principal.home}/nextcloud";
    port = 4000;
    user = app.name;
    # Policy: coolwsd listens on loopback alone, as it binds to no single address, at a port of the app's own, as
    # each nextcloud on a host shares its network.
    officePort = 9980 + app.ids.int;
  };

  package = pkgs.nextcloud35;
  shipped = pkgs.nextcloud35Packages.apps;

  # Dependency: org/apps/nextcloud.nix derives the client, which the keycloak app keeps.
  inherit (app.nextcloud) client;
  secret = "/run/secrets/oidc-secret";
  secretKey = "/run/secrets/secret-key";

  # Fact: occ reads config.php's secrets from systemd's credentials, which a unit gives its own user alone, so a unit
  # that runs it runs as nextcloud and loads them, as nixpkgs' own units do.
  occUnit = config: {
    User = "nextcloud";
    Group = "nextcloud";
    LoadCredential = lib.mapAttrsToList (
      name: file: "${name}:${file}"
    ) config.services.nextcloud.secrets;
  };

  # Policy: a Keycloak user is the Nextcloud user of the same name, which the realm lets no one take or rename to, and
  # the realm is the only way in: the login page sends to it, the users of nextcloud's own are disabled, and a client
  # logs in with an app password, which login flow v2 makes once the user has logged in with the realm. Any user of the
  # realm gets in, as one refused would have no way to log out of it, and one nothing declares can write nothing.
  oidc =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
      keycloak = org.app.${client.keycloak};
      realm = keycloak.keycloak.realms.${client.realm} or { displayName = client.realm; };
    in
    {
      services.nextcloud = {
        extraApps = {
          inherit (shipped) user_oidc;
        };
        settings = {
          user_oidc = {
            auto_provision = true;
            soft_auto_provision = false;
          };
          lost_password_link = "disabled";
          token_auth_enforced = true;
        };
      };
      systemd.services.nextcloud-oidc = {
        description = "keep nextcloud's login with ${client.keycloak}'s realm ${client.realm}, and with it alone";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.jq ];
        serviceConfig = occUnit config // {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${occ} user_oidc:provider ${lib.escapeShellArg realm.displayName} \
            --clientid=${client.representation.clientId} --clientsecret-file=${secret} \
            --discoveryuri=${keycloak.url}/realms/${client.realm}/.well-known/openid-configuration \
            --unique-uid=0 --mapping-uid=preferred_username
          ${occ} config:app:set user_oidc allow_multiple_user_backends --type=string --value=0
          users=$(${occ} user:list --info --limit=0 --output=json)
          jq -r 'to_entries[] | select(.value.backend == "Database" and .value.enabled) | .key' <<<"$users" |
            while IFS= read -r user; do
              ${occ} user:disable "$user"
            done
        '';
      };
    };

  dicts = [
    pkgs.hunspellDicts.sv_SE
    pkgs.hunspellDicts.en_US
  ];

  # Policy: the office is Collabora's, in the container beside Nextcloud, at the app's own url, which Nextcloud's
  # browsers open, Nextcloud asks for its discovery, and Collabora calls back to, and coolwsd serves no other.
  office =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
    in
    {
      services.nextcloud.extraApps = {
        inherit (shipped) richdocuments;
      };
      environment.systemPackages = dicts;
      services.collabora-online = {
        enable = true;
        port = cfg.officePort;
        aliasGroups = [ { host = "${app.url}:${if cfg.ssl then "443" else "80"}"; } ];
        settings = {
          allowed_languages = "en_US sv_SE";
          ssl = {
            enable = false;
            termination = cfg.ssl;
          };
          net = {
            proto = "IPv6";
            listen = "loopback";
          };
          storage.wopi.alias_groups."@mode" = "groups";
        };
      };
      systemd.services.coolwsd = {
        environment.DICPATH = lib.concatMapStringsSep ":" (dict: "${dict}/share/hunspell") dicts;
        preStart = ''
          mkdir -p /var/lib/cool/systemplate/usr/share/hunspell
        ''
        + lib.concatMapStrings (dict: ''
          ln -sf ${dict}/share/hunspell/* /var/lib/cool/systemplate/usr/share/hunspell/
        '') dicts;
      };
      # Fact: richdocuments opens a document only with the discovery it keeps in its appdata, which the home made
      # anew has none of, and which activate-config fetches, through the app's server, once coolwsd answers there.
      systemd.services.nextcloud-office = {
        description = "keep nextcloud's office with its coolwsd";
        after = [
          "nextcloud-setup.service"
          "coolwsd.service"
        ];
        requires = [
          "nextcloud-setup.service"
          "coolwsd.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = occUnit config // {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 5;
        };
        script = ''
          ${occ} richdocuments:activate-config --wopi-url=${lib.escapeShellArg app.url}
        '';
      };
    };

  # Policy: the container's home is its own, and so made anew as it starts, but what's mounted in it: what's
  # Nextcloud's own of it is declared, or in its database, which holds the version Nextcloud is at, as nextcloud-setup
  # records it once it has installed or upgraded. config.php then says it's installed at that version, and Nextcloud
  # upgrades from it rather than install anew.
  ephemeral =
    { config, ... }:
    {
      systemd.services.nextcloud-setup =
        let
          psql = "${postgresql}/bin/psql -h /run/postgresql -U ${cfg.user} -d ${cfg.database} -tAX";
          config_php = "${config.services.nextcloud.datadir}/config/config.php";
        in
        {
          preStart = ''
            if [[ ! -s ${config_php} ]]; then
              version=$(${psql} -c "select value from o11n_nextcloud where key = 'version'" 2>/dev/null) || version=
              if [[ -n $version ]]; then
                printf '<?php\n$CONFIG = [\x27installed\x27 => true, \x27version\x27 => \x27%s\x27];\n' "$version" >${config_php}
                echo '# Nextcloud data directory' >${datadir}/.ncdata
              elif [[ -n $(${psql} -c "select to_regclass('oc_appconfig')") ]]; then
                echo "${cfg.database} holds a nextcloud whose version o11n_nextcloud doesn't say, which nextcloud-setup would install anew over: record it, as in ${cfg.database}'s old config.php, with psql -c \"create table o11n_nextcloud (key text primary key, value text not null); insert into o11n_nextcloud values ('version', '<version>')\"" >&2
                exit 1
              fi
            fi
          '';
          postStart = ''
            version=$(${lib.getExe config.services.nextcloud.occ} config:system:get version)
            ${psql} -c "create table if not exists o11n_nextcloud (key text primary key, value text not null)" \
              -c "insert into o11n_nextcloud values ('version', '$version') on conflict (key) do update set value = excluded.value"
          '';
        };
    };

  # Policy: the users with storages are the drive's, which it makes as it starts, each of the realm's with a
  # Keycloak, and of nextcloud's own without, whose password occ sets. A user nothing declares has a quota of nothing,
  # which lets them write nothing of their own, and one with a home none, as the home is their data. A user's address
  # book and calendar, which dav makes as they first log in, have none of its examples.
  users =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
      psql = "${postgresql}/bin/psql -h /run/postgresql -U ${cfg.user} -d ${cfg.database} -tAX";
      declared = app.nextcloud.users or { };
      made =
        user:
        if client != null then
          "insert into oc_user_oidc (user_id, display_name) values ('${user}', '') on conflict (user_id) do nothing"
        else
          "insert into oc_users (uid, uid_lower, displayname, password) values ('${user}', '${lib.toLower user}', '${user}', '') on conflict (uid) do nothing";
    in
    {
      systemd.services.nextcloud-users = {
        description = "keep nextcloud's users to those with storages";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        before = [ "nextcloud-external.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = occUnit config // {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          lib.concatMapStrings (user: ''
            ${psql} -c ${lib.escapeShellArg (made user)}
          '') (lib.attrNames declared)
          + ''
            ${occ} config:app:set files default_quota --value='0 B'
            ${occ} config:app:set dav enableDefaultContact --type=boolean --value=false
            ${occ} config:app:set dav create_example_event --type=boolean --value=false
          ''
          + lib.concatMapStrings (user: ''
            ${occ} user:setting ${user} files quota none
          '') (lib.attrNames (lib.filterAttrs (_: boxed: boxed) declared));
      };
    };

  # Policy: a nextcloud is a drive: it has the apps of its files and of what its settings call for, and the ones
  # Nextcloud keeps enabled, and nextcloud-apps disables any other each time it starts. The app store is closed.
  apps =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
      kept = [
        "bruteforcesettings"
        "comments"
        "files_downloadlimit"
        "files_lock"
        "files_pdfviewer"
        "files_reminders"
        "files_sharing"
        "files_trashbin"
        "files_versions"
        "logreader"
        "notifications"
        "serverinfo"
        "systemtags"
        "text"
      ]
      ++ lib.attrNames config.services.nextcloud.extraApps
      ++ lib.optional (mounts ++ binds != [ ]) "files_external"
      ++ lib.optionals (client == null) [
        "password_policy"
        "twofactor_totp"
      ];
    in
    {
      systemd.services.nextcloud-apps = {
        description = "keep nextcloud's apps to a drive's";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.jq ];
        serviceConfig = occUnit config // {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          kept=${lib.escapeShellArg (builtins.toJSON kept)}
          always=$(jq -c .alwaysEnabled ${config.services.nextcloud.package}/core/shipped.json)
          enabled=$(${occ} app:list --enabled --output=json)
          mapfile -t others < <(jq -r --argjson kept "$kept" --argjson always "$always" \
            '.enabled | keys - $kept - $always | .[]' <<<"$enabled")
          if ((''${#others[@]})); then
            ${occ} app:disable "''${others[@]}"
          fi
        '';
      };
    };

  mounts = app.nextcloud.mounts.${host.name} or [ ];
  binds = app.nextcloud.binds or [ ];
  bindOf = bind: "/srv/binds/${bind.user}${bind.mountPoint}";
  # Policy: a user without a home has the files no one can write in, which their other storages are folders in.
  unboxed = lib.attrNames (lib.filterAttrs (_: boxed: !boxed) (app.nextcloud.users or { }));
  followed = lib.filter (mount: mount.server.changes or null != null) mounts;
  changesOf =
    mount: "nextcloud-changes-${mount.user}${lib.replaceStrings [ "/" ] [ "-" ] mount.mountPoint}";
  keys = lib.listToAttrs (map (mount: lib.nameValuePair mount.key.handle mount.key) mounts);
  secretOf = handle: "${app.name}/${handle}/sftp-key";
  sftpKey = handle: "/run/secrets/sftp-keys/${handle}";

  shares = app.nextcloud.shares or [ ];
  # Policy: an adapter is a home, as a box is, its owner's, which the host mounts as the app's user's, and what's
  # written there is written as its owner.
  adapters = app.nextcloud.adapters or [ ];
  homes = shares ++ adapters;
  contained = [
    app.secrets
  ]
  ++ lib.optional (client != null) client.secret
  ++ map (key: key.secret) (lib.attrValues keys);
  datadir = "/var/lib/nextcloud/data";
  postgresql = config.services.postgresql.package;
  dataOf = user: "${cfg.home}/data/${user}";
  passwordOf = handle: "${app.name}/${handle}/smb-password";
  credentialsOf = user: "${app.name}/${user}-smb-credentials";

  # Dependency: crates/o11n/src/nextcloud.rs reads this through switch-system nextcloud, a line each:
  # <app> home <user> ok|<why not>, <app> external <user>/<folder> ok|<why not> and <app> changes <user>/<folder>
  # ok|<why not>.
  status = pkgs.writeShellApplication {
    name = "nextcloud-status-${cfg.name}";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nixos-container
      pkgs.util-linux
    ];
    text = ''
      say() {
        echo "${cfg.name} $1 $2 ''${3//$'\n'/ }"
      }
      occ() {
        timeout 60 nixos-container run ${cfg.name} -- nextcloud-occ "$@"
      }
    ''
    + lib.concatMapStrings (home: ''
      path=${lib.escapeShellArg (dataOf home.user)}
      if ! timeout 20 mountpoint -q "$path"; then
        say home ${home.user} "$path isn't mounted: systemctl status $path"
      elif ! timeout 20 runuser -u ${cfg.user} -- test -w "$path"; then
        say home ${home.user} "$path isn't writable as ${cfg.user}"
      else
        say home ${home.user} ok
      fi
    '') homes
    + lib.optionalString (mounts ++ binds != [ ]) (
      ''
        listed=$(occ files_external:list --output=json 2>/dev/null) || listed=
      ''
      + lib.concatMapStrings (
        mount:
        let
          name = "${mount.user}${mount.mountPoint}";
        in
        ''
          if [[ -z $listed ]]; then
            say external ${name} "files_external:list fails in ${cfg.name}'s container: machinectl status ${cfg.name}"
          else
            id=$(jq -r --arg point ${mount.mountPoint} --arg user ${mount.user} \
              'first(.[] | select(.mount_point == $point and .applicable_users == [$user]) | .mount_id) // empty' \
              <<<"$listed" 2>/dev/null) || id=
            if [[ -z $id ]]; then
              say external ${name} "${cfg.name} has no external storage ${mount.mountPoint} for ${mount.user}: journalctl -M ${cfg.name} -u nextcloud-external"
            elif ! verified=$(occ files_external:verify "$id" --output=json 2>&1); then
              say external ${name} "files_external:verify $id fails: $verified"
            elif ! said=$(jq -er '"\(.status): \(.message)"' <<<"$verified" 2>/dev/null); then
              say external ${name} "files_external:verify $id says: $verified"
            elif [[ $said != "ok: "* ]]; then
              say external ${name} "$said"
            else
              say external ${name} ok
            fi
          fi
        ''
      ) (mounts ++ binds)
    )
    # Policy: a listener that can't connect is active for no more than its ssh's ConnectTimeout before it restarts, so
    # one active for longer is connected.
    + lib.concatMapStrings (
      mount:
      let
        unit = "${changesOf mount}.service";
      in
      ''
        if ! shown=$(timeout 20 nixos-container run ${cfg.name} -- \
          systemctl show --timestamp=unix -P ActiveState -P ActiveEnterTimestamp ${unit} 2>&1); then
          say changes ${mount.user}${mount.mountPoint} "systemctl show ${unit} fails in ${cfg.name}'s container: $shown"
        else
          { read -r state; read -r entered; } <<<"$shown"
          since=$(($(date +%s) - ''${entered#@}))
          if [[ $state != active ]]; then
            say changes ${mount.user}${mount.mountPoint} "${unit} is $state: journalctl -M ${cfg.name} -u ${unit}"
          elif ((since < 20)); then
            say changes ${mount.user}${mount.mountPoint} "${unit} started ''${since}s ago, as it does each time it can't connect: journalctl -M ${cfg.name} -u ${unit}"
          else
            say changes ${mount.user}${mount.mountPoint} ok
          fi
        fi
      ''
    ) followed;
  };

  # Policy: each start makes each mount as declared, replacing what is at its mount point for its user otherwise. It
  # imports rather than sets the mount, as the import reads the private key on stdin, and files_external:config would
  # take it on its command line, which any user on the host can read.
  external =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
      keep =
        mount:
        let
          local = mount ? path;
          declared = {
            mount_id = null;
            mount_point = mount.mountPoint;
            options.enable_sharing = mount.sharing;
            applicable_users = [ mount.user ];
            applicable_groups = [ ];
          }
          // (
            if local then
              {
                storage = "\\OC\\Files\\Storage\\Local";
                authentication_type = "null::null";
                configuration.datadir = bindOf mount;
              }
            else
              {
                storage = "\\OCA\\Files_External\\Lib\\Storage\\SFTP";
                authentication_type = "publickey::rsa";
                configuration = {
                  inherit (mount.server) host root;
                  user = mount.server.login;
                  public_key = lib.optionalString (builtins.pathExists mount.key.publicKey) (
                    lib.trim (builtins.readFile mount.key.publicKey)
                  );
                };
              }
          );
        in
        ''
          declared=${lib.escapeShellArg (builtins.toJSON declared)}
          current=$(jq --argjson declared "$declared" \
            '[.[] | select(.mount_point == $declared.mount_point and .applicable_users == $declared.applicable_users)]' \
            <<<"$mounts")
          if ! jq -e --argjson declared "$declared" \
            'length == 1 and (.[0] as $c | ["configuration", "options"]
              | all(. as $part | $declared[$part] | to_entries | all(.value == $c[$part][.key])))' \
            <<<"$current" >/dev/null; then
            for id in $(jq -r '.[].mount_id' <<<"$current"); do
              ${occ} files_external:delete --yes "$id"
            done
            ${
              if local then
                ''${occ} files_external:import - <<<"$declared"''
              else
                ''
                  jq --rawfile key ${sftpKey mount.key.handle} '.configuration.private_key = $key' <<<"$declared" \
                    | ${occ} files_external:import -
                ''
            }
          fi
        '';
    in
    {
      systemd.services = {
        nextcloud-external = {
          description = "keep nextcloud's external storages as declared";
          after = [ "nextcloud-setup.service" ];
          requires = [ "nextcloud-setup.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.jq ];
          serviceConfig = occUnit config // {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${occ} app:enable files_external
            mounts=$(${occ} files_external:list --show-password --output=json)
            ${lib.concatMapStrings keep (mounts ++ binds)}
          '';
        };
      }
      # Policy: SFTP tells nextcloud nothing of what changes underneath, and the etags its clients sync by change only
      # as it scans, so for a mount of an allotment with replicas it follows what they change, and scans the mount as
      # it connects, to catch up, and as they change it, once they've been quiet for 5 seconds. files:scan exits 0
      # with errors, which it counts in its summary alone, so the listener restarts on a scan with any, to scan again.
      // lib.listToAttrs (
        map (
          mount:
          let
            inherit (mount.server) changes;
            knownHosts = pkgs.writeText "known-hosts" "${mount.server.host} ${lib.trim (builtins.readFile changes.hostKey)}\n";
          in
          lib.nameValuePair (changesOf mount) {
            description = "scan ${mount.user}'s ${mount.mountPoint} as its allotment's replicas change it";
            after = [ "nextcloud-external.service" ];
            requires = [ "nextcloud-external.service" ];
            wantedBy = [ "multi-user.target" ];
            path = [
              pkgs.gawk
              pkgs.openssh
            ];
            serviceConfig = occUnit config // {
              Restart = "always";
              RestartSec = 10;
            };
            script = ''
              while read -r _; do
                while read -r -t 5 _; do :; done
                scanned=$(${occ} files:scan --verbose --no-interaction --path=${lib.escapeShellArg "${mount.user}/files${mount.mountPoint}"})
                if ! awk -F '|' '$7 ~ /^ *[0-9]+ *$/ { errors = $7 } END { exit errors + 0 > 0 }' <<<"$scanned"; then
                  echo "$scanned" >&2
                  exit 1
                fi
              done < <(ssh -T -i ${sftpKey mount.key.handle} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${knownHosts} \
                -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
                ${changes.login}@${mount.server.host} ${changes.id})
            '';
          }
        ) followed
      );
    };

in
{
  imports = [
    ../postgresql.nix
  ];

  config = {
    sops.secrets = {
      "${app.name}/secret-key" = {
        inherit (app.secrets) sopsFile;
        owner = app.name;
        group = app.name;
      };
    }
    // lib.optionalAttrs (client != null) {
      ${client.secret.name} = {
        inherit (client.secret) sopsFile;
        owner = app.name;
        group = app.name;
      };
    }
    // lib.mapAttrs' (
      handle: key:
      lib.nameValuePair (secretOf handle) {
        inherit (key.secret) sopsFile;
        key = key.secret.name;
        owner = app.name;
        group = app.name;
      }
    ) keys
    // lib.listToAttrs (
      map (
        share:
        lib.nameValuePair (passwordOf share.key.handle) {
          inherit (share.key.secret) sopsFile;
          key = share.key.secret.name;
        }
      ) shares
    );

    sops.templates = lib.listToAttrs (
      map (
        share:
        lib.nameValuePair (credentialsOf share.user) {
          content = ''
            username=${share.login}
            password=${config.sops.placeholder.${passwordOf share.key.handle}}
          '';
        }
      ) shares
    );

    # Policy: the share is mounted as the app's user, and the container starts only once it is, so that Nextcloud never
    # writes the user's data to the directory beneath.
    fileSystems = lib.listToAttrs (
      map (
        share:
        lib.nameValuePair (dataOf share.user) {
          device = "//${share.host}/${share.share}";
          fsType = "cifs";
          options = [
            "credentials=${config.sops.templates.${credentialsOf share.user}.path}"
            "uid=${toString cfg.uid}"
            "gid=${toString cfg.gid}"
            "dir_mode=0750"
            "file_mode=0640"
            "vers=3.1.1"
            "seal"
            "_netdev"
            "nofail"
            "x-systemd.after=network-online.target"
            "x-systemd.requires=network-online.target"
          ];
        }
      ) shares
    );

    environment.systemPackages = lib.optional (homes ++ mounts ++ binds != [ ]) status;

    # Policy: the container connects as the host user with its uid, by peer authentication.
    assertions = [
      {
        assertion = (config.users.users.${cfg.user}.uid or null) == cfg.uid;
        message = "Nextcloud ${cfg.name} connects to postgresql as the host's user ${cfg.user}, whose uid has to be ${toString cfg.uid}.";
      }
    ]
    ++ map (mount: {
      assertion = builtins.pathExists mount.server.changes.hostKey;
      message = "Nextcloud ${cfg.name} follows what changes in ${mount.user}'s ${mount.mountPoint} on ${mount.server.host} by ssh, verifying its host's ssh-key, which it has none of: o11n host pull-ssh-key on that host.";
    }) followed
    ++ map (adapter: {
      assertion = config.users.users ? ${adapter.owner};
      message = "Nextcloud ${cfg.name} mounts ${adapter.user}'s home from ${adapter.path}, whose owner, ${adapter.owner}, isn't on ${host.name}: run the owner on ${host.name}, or drop the adapter.";
    }) adapters
    ++ lib.mapAttrsToList (handle: key: {
      assertion = builtins.pathExists key.publicKey;
      message = "Nextcloud ${cfg.name} logs in to an external storage with ${handle}'s sftp-key, which it has none of: o11n secret generate ${handle} sftp-key.";
    }) keys;

    o11n.postgresql = {
      databases = {
        ${cfg.database} = { inherit (cfg) user; };
      };
      # Fact: the container reaches it through a bind of /run/postgresql, which postgresql makes
      # anew each time it starts.
      containers = [ cfg.name ];
    };

    systemd.tmpfiles.rules = lib.optionals (homes != [ ]) [
      "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -"
      "d '${cfg.home}/data' 0750 ${cfg.user} ${cfg.user} - -"
    ];

    system.fsPackages = lib.optional (adapters != [ ]) pkgs.bindfs;

    # Fact: a mount unit with nofail isn't ordered before local-fs.target, so it can follow systemd-tmpfiles-setup,
    # which makes the home it mounts in.
    systemd.mounts = map (adapter: {
      what = adapter.path;
      where = dataOf adapter.user;
      type = "fuse.bindfs";
      options = lib.concatStringsSep "," [
        "force-user=${cfg.user}"
        "force-group=${cfg.user}"
        "create-for-user=${adapter.owner}"
        "create-for-group=${adapter.owner}"
        "nofail"
      ];
      after = [ "systemd-tmpfiles-setup.service" ];
      wantedBy = [ "multi-user.target" ];
    }) adapters;

    systemd.services = {
      # Fact: the container binds each secret's file as it starts, and a switch to another of its values restarts
      # nothing, as NixOS 26.11's activation no longer restarts what restartUnits names.
      "container@${cfg.name}" = {
        restartTriggers = map (file: builtins.hashFile "sha256" file) (
          lib.unique (map (secret: secret.sopsFile) contained)
        );
        unitConfig.RequiresMountsFor = map (home: dataOf home.user) homes;
        serviceConfig = {
          TimeoutStopSec = 10;
          KillMode = "mixed";
        };
      };
    };

    services.nginx.virtualHosts = {
      ${cfg.endpoint} = {
        forceSSL = cfg.ssl;
        enableACME = cfg.ssl;
        extraConfig = ''
          client_max_body_size 1G;
        '';

        locations =
          let
            office = {
              proxyPass = "http://[::1]:${toString cfg.officePort}";
              extraConfig = ''
                proxy_set_header Host $host;
              '';
            };
            websocket = office // {
              proxyWebsockets = true;
              extraConfig = office.extraConfig + ''
                proxy_read_timeout 36000s;
              '';
            };
          in
          {
            "/" = {
              proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
            };
            "^~ /browser" = office;
            "^~ /hosting/discovery" = office;
            "^~ /hosting/capabilities" = office;
            "~ ^/cool/(.*)/ws$" = websocket // {
              priority = 1;
            };
            "^~ /cool/adminws" = websocket;
            "~ ^/(c|l)ool" = office;
          };
      };
    };

    containers = {
      ${cfg.name} = {
        autoStart = true;
        ephemeral = true;

        bindMounts = {
          "/run/postgresql" = {
            isReadOnly = false;
          };
          ${secretKey} = {
            hostPath = config.sops.secrets."${app.name}/secret-key".path;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (client != null) {
          ${secret} = {
            hostPath = config.sops.secrets.${client.secret.name}.path;
            isReadOnly = true;
          };
        }
        // lib.mapAttrs' (
          handle: _:
          lib.nameValuePair (sftpKey handle) {
            hostPath = config.sops.secrets.${secretOf handle}.path;
            isReadOnly = true;
          }
        ) keys
        // lib.listToAttrs (
          map (
            home:
            lib.nameValuePair "${datadir}/${home.user}" {
              hostPath = dataOf home.user;
              isReadOnly = false;
            }
          ) homes
          ++ map (
            bind:
            lib.nameValuePair (bindOf bind) {
              hostPath = bind.path;
              isReadOnly = false;
            }
          ) binds
          ++ map (
            user:
            lib.nameValuePair "${datadir}/${user}/files" {
              hostPath = "${pkgs.emptyDirectory}";
              isReadOnly = true;
            }
          ) unboxed
        );

        config = {
          imports = [
            apps
            ephemeral
            users
          ]
          ++ lib.optional (client != null) oidc
          ++ [ office ]
          ++ lib.optional (mounts ++ binds != [ ]) external;
          system.stateVersion = config.system.stateVersion;

          systemd.tmpfiles.rules = map (user: "d '${datadir}/${user}' 0750 nextcloud nextcloud - -") unboxed;

          users.users.nextcloud.uid = cfg.uid;
          users.groups.nextcloud.gid = cfg.gid;

          environment.systemPackages = [ config.services.postgresql.package ];

          services.nginx = {
            virtualHosts.localhost = {
              extraConfig = ''
                set_real_ip_from ${cfg.bindAddress}/128;
                real_ip_header X-Forwarded-For;
                real_ip_recursive on;
              '';
              listen = [
                {
                  addr = "[${cfg.bindAddress}]";
                  inherit (cfg) port;
                }
              ];
            };
          };

          systemd.services.nextcloud-setup = {
            after = [
              "redis-nextcloud.service"
            ];
            requires = [
              "redis-nextcloud.service"
            ];
          };

          services.nextcloud = {
            enable = true;
            https = cfg.ssl;
            hostName = "localhost";
            inherit package;
            appstoreEnable = false;
            # Policy: config.php's secret, which what Nextcloud encrypts in its database is encrypted with, and its
            # passwordsalt are the app's secret-key, and its instanceid, which names its appdata, follows from the
            # app's id, so that its home, made anew, reads its database as it did.
            secrets = {
              secret = secretKey;
              passwordsalt = secretKey;
            };
            maxUploadSize = "1G";
            settings = {
              trusted_proxies = [
                cfg.bindAddress
              ];
              trusted_domains = [
                cfg.endpoint
              ];
              instanceid = "oc${app.ids.hex8}";
              # Policy: the trash empties of what's 30 days old, and versions, thinned as Nextcloud does, of what's a
              # year old: Nextcloud's own deletes only for room, which users without a quota never run out of.
              trashbin_retention_obligation = "auto, 30";
              versions_retention_obligation = "auto, 365";
              defaultapp = "files";
              skeletondirectory = "";
              default_phone_region = "SE";
              overwriteprotocol = app.scheme;
              forwarded_for_headers = [ "HTTP_X_FORWARDED_FOR" ];
              "simpleSignUpLink.shown" = false;
              # Accommodating for files_external:import, which leaves out the mount option the web UI sets: each
              # storage, a box too, checks a folder for changes as it's opened, rather than never.
              filesystem_check_changes = 1;
              files_external_allow_create_new_local = binds != [ ];
            };
            phpOptions = {
              "opcache.interned_strings_buffer" = 23;
            };
            configureRedis = true;
            caching = {
              redis = true;
              memcached = true;
            };
            config = {
              dbtype = "pgsql";
              dbhost = "/run/postgresql";
              dbuser = cfg.user;
              dbname = cfg.database;
            };
          };
        };
      };
    };
  };
}
