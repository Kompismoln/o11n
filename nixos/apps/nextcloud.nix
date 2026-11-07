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
    collaboraEndpoint = lib.mapNullable (
      collabora: org.app.${collabora}.endpoint
    ) app.nextcloud.collabora;
  };

  # Dependency: org/apps/nextcloud.nix derives the client, which the keycloak app keeps.
  inherit (app.nextcloud) client;
  secret = "/run/secrets/oidc-secret";

  # Policy: a Keycloak user is the Nextcloud user of the same name, which the realm lets no one take or rename to:
  # user_oidc's soft auto-provisioning has a login of an account made before it the account's.
  oidc =
    { config, ... }:
    let
      keycloak = org.app.${client.keycloak};
      realm = keycloak.keycloak.realms.${client.realm} or { displayName = client.realm; };
    in
    {
      services.nextcloud.extraApps = {
        inherit (pkgs.nextcloud34Packages.apps) user_oidc;
      };
      systemd.services.nextcloud-oidc = {
        description = "keep nextcloud's login with ${client.keycloak}'s realm ${client.realm}";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe config.services.nextcloud.occ} user_oidc:provider ${lib.escapeShellArg realm.displayName} \
            --clientid=${client.representation.clientId} --clientsecret-file=${secret} \
            --discoveryuri=${keycloak.url}/realms/${client.realm}/.well-known/openid-configuration \
            --unique-uid=0 --mapping-uid=preferred_username
        '';
      };
    };

  mounts = app.nextcloud.mounts.${host.name} or [ ];
  sftpKey = "/run/secrets/sftp-key";

  # Policy: each start makes each mount as declared, replacing what is at its mount point for its user otherwise. It
  # imports rather than sets the mount, as the import reads the private key on stdin, and files_external:config would
  # take it on its command line, which any user on the host can read.
  allotments =
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
              host = "[${mount.address}]";
              inherit (mount) root user;
              public_key = lib.optionalString (builtins.pathExists app.publicKeys.sftp-key) (
                lib.trim (builtins.readFile app.publicKeys.sftp-key)
              );
            };
            options = { };
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
            'length == 1 and (.[0].configuration as $c | $declared.configuration | to_entries | all(.value == $c[.key]))' \
            <<<"$current" >/dev/null; then
            for id in $(jq -r '.[].mount_id' <<<"$current"); do
              ${occ} files_external:delete --yes "$id"
            done
            jq --rawfile key ${sftpKey} '.configuration.private_key = $key' <<<"$declared" \
              | ${occ} files_external:import -
          fi
        '';
    in
    {
      systemd.services.nextcloud-allotments = {
        description = "keep nextcloud's mounts of the allotments it's given";
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.jq ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${occ} app:enable files_external
          mounts=$(${occ} files_external:list --show-password --output=json)
          ${lib.concatMapStrings keep mounts}
        '';
      };
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
    // lib.optionalAttrs (mounts != [ ]) {
      "${app.name}/sftp-key" = {
        inherit (app.secrets) sopsFile;
        owner = app.name;
        group = app.name;
      };
    };

    # Policy: the container connects as the host user with its uid, by peer authentication.
    assertions = [
      {
        assertion = (config.users.users.${cfg.user}.uid or null) == cfg.uid;
        message = "Nextcloud ${cfg.name} connects to postgresql as the host's user ${cfg.user}, whose uid has to be ${toString cfg.uid}.";
      }
    ]
    ++ lib.optional (mounts != [ ]) {
      assertion = builtins.pathExists app.publicKeys.sftp-key;
      message = "Nextcloud ${cfg.name} logs in to the allotments it mounts with ${app.handle}'s sftp-key, which it has none of: o11n secret generate ${app.handle} sftp-key.";
    };

    o11n.postgresql = {
      databases = {
        ${cfg.database} = { inherit (cfg) user; };
      };
      # Fact: the container reaches it through a bind of /run/postgresql, which postgresql makes
      # anew each time it starts.
      containers = [ cfg.name ];
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -"
    ];

    systemd.services = {
      "container@${cfg.name}" = {
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
          "/.well-known/carddav" = {
            return = "301 $scheme://$host/remote.php/dav";
          };

          "/.well-known/caldav" = {
            return = "301 $scheme://$host/remote.php/dav";
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
        }
        // lib.optionalAttrs (client != null) {
          ${secret} = {
            hostPath = config.sops.secrets.${client.secret.name}.path;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (mounts != [ ]) {
          ${sftpKey} = {
            hostPath = config.sops.secrets."${app.name}/sftp-key".path;
            isReadOnly = true;
          };
        };

        config = {
          imports = lib.optional (client != null) oidc ++ lib.optional (mounts != [ ]) allotments;
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
            package = pkgs.nextcloud34;
            appstoreEnable = true;
            maxUploadSize = "1G";
            extraApps = {
              inherit (pkgs.nextcloud34Packages.apps) calendar;
            };
            settings = {
              trusted_proxies = [
                cfg.bindAddress
              ];
              trusted_domains = [
                cfg.endpoint
              ]
              ++ lib.optional (cfg.collaboraEndpoint != null) cfg.collaboraEndpoint;
              default_phone_region = "SE";
              overwriteprotocol = app.scheme;
              forwarded_for_headers = [ "HTTP_X_FORWARDED_FOR" ];
              "simpleSignUpLink.shown" = false;
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
