{
  app,
  config,
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
    };

    # Policy: the container connects as the host user with its uid, by peer authentication.
    assertions = [
      {
        assertion = (config.users.users.${cfg.user}.uid or null) == cfg.uid;
        message = "Nextcloud ${cfg.name} connects to postgresql as the host's user ${cfg.user}, whose uid has to be ${toString cfg.uid}.";
      }
    ];

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
        };

        config = {
          imports = lib.optional (client != null) oidc;
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
