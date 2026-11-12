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
    collabora = lib.mapNullable (collabora: org.app.${collabora}) app.nextcloud.collabora;
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
  # logs in with an app password, which login flow v2 makes once the user has logged in with the realm.
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
          user_oidc.soft_auto_provision = false;
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

  # Policy: the office is the collabora app's, at its url, which Nextcloud's browsers open and Collabora calls back
  # from as they find it.
  office =
    { config, ... }:
    let
      occ = lib.getExe config.services.nextcloud.occ;
    in
    {
      services.nextcloud.extraApps = {
        inherit (shipped) richdocuments;
      };
      systemd.services.nextcloud-office = {
        description = "keep nextcloud's office with ${app.nextcloud.collabora}";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = occUnit config // {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${occ} config:app:set richdocuments wopi_url --value=${lib.escapeShellArg cfg.collabora.url}
          ${occ} config:app:delete richdocuments public_wopi_url
          ${occ} config:app:delete richdocuments wopi_callback_url
        '';
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
      ++ lib.optional (mounts != [ ]) "files_external"
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
  followed = lib.filter (mount: mount.server.changes or null != null) mounts;
  changesOf =
    mount: "nextcloud-changes-${mount.user}${lib.replaceStrings [ "/" ] [ "-" ] mount.mountPoint}";
  keys = lib.listToAttrs (map (mount: lib.nameValuePair mount.key.handle mount.key) mounts);
  secretOf = handle: "${app.name}/${handle}/sftp-key";
  sftpKey = handle: "/run/secrets/sftp-keys/${handle}";

  shares = app.nextcloud.shares or [ ];
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
    + lib.concatMapStrings (share: ''
      path=${lib.escapeShellArg (dataOf share.user)}
      if ! timeout 20 mountpoint -q "$path"; then
        say home ${share.user} "$path isn't mounted: systemctl status $path"
      elif ! timeout 20 runuser -u ${cfg.user} -- test -w "$path"; then
        say home ${share.user} "$path isn't writable as ${cfg.user}"
      else
        say home ${share.user} ok
      fi
    '') shares
    + lib.optionalString (mounts != [ ]) (
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
      ) mounts
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
          declared = {
            mount_id = null;
            mount_point = mount.mountPoint;
            storage = "\\OCA\\Files_External\\Lib\\Storage\\SFTP";
            authentication_type = "publickey::rsa";
            configuration = {
              inherit (mount.server) host root;
              user = mount.server.login;
              public_key = lib.optionalString (builtins.pathExists mount.key.publicKey) (
                lib.trim (builtins.readFile mount.key.publicKey)
              );
            };
            options.enable_sharing = mount.sharing;
            applicable_users = [ mount.user ];
            applicable_groups = [ ];
          };
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
            jq --rawfile key ${sftpKey mount.key.handle} '.configuration.private_key = $key' <<<"$declared" \
              | ${occ} files_external:import -
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
            ${lib.concatMapStrings keep mounts}
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

    environment.systemPackages = lib.optional (shares != [ ] || mounts != [ ]) status;

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

    # Policy: an archive of the app's home leaves out what Nextcloud makes anew: previews, and each user's cache and
    # uploads in progress.
    systemd.tmpfiles.rules = [
      "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -"
      "d '${cfg.home}/data' 0750 ${cfg.user} ${cfg.user} - -"
      "f+ '${cfg.home}/data/.resticignore' 0640 ${cfg.user} ${cfg.user} - appdata_*/preview\\n*/cache\\n*/uploads\\n"
    ];

    systemd.services = {
      "container@${cfg.name}" = {
        unitConfig.RequiresMountsFor = map (share: dataOf share.user) shares;
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

        locations = {
          "/" = {
            proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
          };
        };
      };
    };

    containers = {
      ${cfg.name} = {
        autoStart = true;
        ephemeral = true;

        bindMounts = {
          ${config.services.nextcloud.home} = {
            isReadOnly = false;
            hostPath = cfg.home;
          };
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
        ) keys;

        config = {
          imports = [
            apps
          ]
          ++ lib.optional (client != null) oidc
          ++ lib.optional (cfg.collabora != null) office
          ++ lib.optional (mounts != [ ]) external;
          system.stateVersion = config.system.stateVersion;

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
            # Policy: config.php's secret, which what Nextcloud encrypts in its database is encrypted with, is the
            # app's secret-key, and its instanceid, which names its appdata, follows from the app's id, so a database
            # restored to a nextcloud installed anew reads as it did.
            secrets.secret = secretKey;
            maxUploadSize = "1G";
            settings = {
              trusted_proxies = [
                cfg.bindAddress
              ];
              trusted_domains = [
                cfg.endpoint
              ]
              ++ lib.optional (cfg.collabora != null) cfg.collabora.endpoint;
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
              # storage, a home on SMB too, checks a folder for changes as it's opened, rather than never.
              filesystem_check_changes = 1;
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
