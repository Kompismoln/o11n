# nixos/apps/nextcloud.nix
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

in
{
  imports = [
    ../postgresql.nix
  ];

  config = {
    sops.secrets."${app.name}/secret-key" = {
      inherit (app.secrets) sopsFile;
      owner = app.name;
      group = app.name;
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
        };

        config = {
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
            https = true;
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
                cfg.collaboraEndpoint
              ];
              default_phone_region = "SE";
              overwriteprotocol = "https";
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
