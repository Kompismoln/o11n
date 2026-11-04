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
  eachApp.${app.name} = {
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
    assertions = lib.mapAttrsToList (_: app: {
      assertion = (config.users.users.${app.user}.uid or null) == app.uid;
      message = "Nextcloud ${app.name} connects to postgresql as the host's user ${app.user}, whose uid has to be ${toString app.uid}.";
    }) eachApp;

    o11n.postgresql = {
      databases = lib.mapAttrs' (_: app: lib.nameValuePair app.database { inherit (app) user; }) eachApp;
      # Fact: the container reaches it through a bind of /run/postgresql, which postgresql makes
      # anew each time it starts.
      containers = lib.attrNames eachApp;
    };

    systemd.tmpfiles.rules = lib.concatMap (app: [
      "d '${app.home}' 0750 ${app.user} ${app.user} - -"
    ]) (lib.attrValues eachApp);

    systemd.services = lib.mapAttrs' (
      _: app:
      lib.nameValuePair "container@${app.name}" {
        serviceConfig = {
          TimeoutStopSec = 10;
          KillMode = "mixed";
        };
      }
    ) eachApp;

    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      lib.nameValuePair app.endpoint {
        forceSSL = app.ssl;
        enableACME = app.ssl;
        extraConfig = ''
          client_max_body_size 1G;
        '';

        locations = {
          "/" = {
            proxyPass = "http://[${app.bindAddress}]:${toString app.port}";
          };
          "/.well-known/carddav" = {
            return = "301 $scheme://$host/remote.php/dav";
          };

          "/.well-known/caldav" = {
            return = "301 $scheme://$host/remote.php/dav";
          };
        };
      }
    ) eachApp;

    containers = lib.mapAttrs (_: app: {
      autoStart = true;
      ephemeral = true;

      bindMounts = {
        ${config.services.nextcloud.home} = {
          isReadOnly = false;
          hostPath = app.home;
        };
        "/run/postgresql" = {
          isReadOnly = false;
        };
      };

      config = {
        system.stateVersion = config.system.stateVersion;

        users.users.nextcloud.uid = app.uid;
        users.groups.nextcloud.gid = app.gid;

        environment.systemPackages = [ config.services.postgresql.package ];

        services.nginx = {
          virtualHosts.localhost = {
            extraConfig = ''
              set_real_ip_from ${app.bindAddress}/128;
              real_ip_header X-Forwarded-For;
              real_ip_recursive on;
            '';
            listen = [
              {
                addr = "[${app.bindAddress}]";
                inherit (app) port;
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
              app.bindAddress
            ];
            trusted_domains = [
              app.endpoint
              app.collaboraEndpoint
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
            dbuser = app.user;
            dbname = app.database;
          };
        };
      };
    }) eachApp;
  };
}
