{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.nextcloud;

  eachApp = lib.filterAttrs (_app: appCfg: appCfg.enable) cfg.apps;

  appOpts = {
    options = {
      enable = lib.mkEnableOption "nextcloud";
      name = lib.mkOption {
        description = "app name";
        type = lib.types.str;
      };
      endpoint = lib.mkOption {
        description = "app's endpoint";
        type = lib.types.str;
      };
      home = lib.mkOption {
        description = "app's home";
        type = lib.types.str;
      };
      package = lib.mkOption {
        description = "app package";
        type = lib.types.package;
      };
      bindAddress = lib.mkOption {
        description = "address this app should bind to";
        type = lib.types.str;
      };
      uid = lib.mkOption {
        description = "host user id for container mirroring";
        type = lib.types.int;
      };
      gid = lib.mkOption {
        description = "group id for container mirroring";
        type = lib.types.int;
      };
      secretKeyPath = lib.mkOption {
        description = "path to secret key file";
        type = lib.types.str;
      };
      port = lib.mkOption {
        description = "port";
        type = lib.types.port;
        default = 4000;
      };
      ssl = lib.mkOption {
        description = "force encrypted connections";
        type = lib.types.bool;
        default = true;
      };
      database = lib.mkOption {
        description = "database name";
        type = lib.types.str;
        default = config.name;
      };
      user = lib.mkOption {
        description = "user name";
        type = lib.types.str;
        default = config.name;
      };
      collaboraEndpoint = lib.mkOption {
        description = "collabora endpoint";
        type = with lib.types; nullOr str;
      };
    };
  };
in
{
  options = {
    o11n.nextcloud = {
      apps = lib.mkOption {
        type = with lib.types; attrsOf (submodule appOpts);
        default = { };
        description = "nextcloud instances to serve";
      };
    };
  };

  config = lib.mkIf (eachApp != { }) {

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
        "/run/secrets/db-password" = {
          isReadOnly = true;
          hostPath = app.secretKeyPath;
        };
        "/run/secrets/admin-password" = {
          isReadOnly = true;
          hostPath = app.secretKeyPath;
        };
      };

      config = {
        system.stateVersion = config.system.stateVersion;

        users.users.nextcloud.uid = app.uid;
        users.groups.nextcloud.gid = app.gid;

        environment.systemPackages = [ pkgs.postgresql ];

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
            dbhost = "localhost";
            dbpassFile = "/run/secrets/db-password";
            dbuser = app.user;
            dbname = app.database;
            adminpassFile = "/run/secrets/admin-password";
          };
        };
      };
    }) eachApp;
  };
}
