{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.mobilizon;

  mobilizonOpts =
    { config, ... }:
    {
      options = {
        enable = lib.mkEnableOption "mobilizon";
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
      };
    };

  eachApp = lib.filterAttrs (_app: appCfg: appCfg.enable) cfg.apps;

  hostConfig = config;
in
{
  options = {
    o11n.mobilizon = {
      apps = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule mobilizonOpts);
        default = { };
        description = "mobilizon apps to serve";
      };
    };
  };

  config = lib.mkIf (eachApp != { }) {
    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      let
        proxyPass = "http://[${app.bindAddress}]:${toString app.port}";
      in
      lib.nameValuePair app.endpoint {
        forceSSL = app.ssl;
        enableACME = app.ssl;

        locations = {
          "/" = {
            inherit proxyPass;
            recommendedProxySettings = lib.mkDefault true;
            extraConfig = ''
              expires off;
              add_header Cache-Control "public, max-age=0, s-maxage=0, must-revalidate" always;
            '';
          };
        };
        locations."~ ^/(assets|img)" = {
          root = "${app.package}/lib/mobilizon-${app.package.version}/priv/static";
          extraConfig = ''
            access_log off;
            add_header Cache-Control "public, max-age=31536000, s-maxage=31536000, immutable";
          '';
        };
        locations."/graphql_socket/websocket" = {
          inherit proxyPass;
          recommendedProxySettings = lib.mkDefault true;
          extraConfig = ''
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
          '';
        };
        locations."~ ^/(media|proxy)" = {
          inherit proxyPass;
          recommendedProxySettings = lib.mkDefault true;
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_request_buffering off;
            access_log off;
            add_header Cache-Control "public, max-age=31536000, s-maxage=31536000, immutable";
          '';
        };
      }
    ) eachApp;

    systemd.services = lib.mapAttrs' (
      _: app:
      lib.nameValuePair "container@${app.name}" {
        serviceConfig = {
          TimeoutStopSec = 10;
          KillMode = "mixed";
        };
      }
    ) eachApp;

    containers = lib.mapAttrs' (
      _: app:
      (lib.nameValuePair app.name {
        autoStart = true;
        ephemeral = true;

        bindMounts = {
          "/var/lib/mobilizon" = {
            isReadOnly = false;
            hostPath = app.home;
          };
          "/run/postgresql" = {
            isReadOnly = false;
          };
        };

        config = {
          system = {
            inherit (hostConfig.system) stateVersion;
          };
          users = {
            users.mobilizon = {
              inherit (app) uid;
              group = "mobilizon";
            };
            groups.mobilizon.gid = app.gid;
          };

          services.postgresql.enable = lib.mkForce false;
          services.postgresql.package = pkgs.postgresql_17;
          systemd.services.mobilizon-postgresql.enable = lib.mkForce false;

          environment.systemPackages = [ pkgs.postgresql_17 ];

          systemd.services.mobilizon = {
            path = [ pkgs.postgresql ];

          };
          # ...
          services.mobilizon =
            let
              elixirConf = pkgs.formats.elixirConf { elixir = app.package.elixirPackage; };
            in
            {
              enable = true;
              inherit (app) package;
              nginx.enable = false;
              settings.":mobilizon" = {
                "Mobilizon.Web.Endpoint".http = {
                  inherit (app) port;
                  ip = elixirConf.lib.mkRaw ''elem(:inet.parse_address(~c"${app.bindAddress}"), 1)'';
                };
                "Mobilizon.Storage.Repo" = {
                  inherit (app) database;
                  socket_dir = "/run/postgresql";
                  username = app.user;
                };
                ":instance" = {
                  inherit (app) name;
                  hostname = app.endpoint;
                };
              };

            };
        };

      })
    ) eachApp;
  };
}
