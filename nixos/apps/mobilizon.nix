# nixos/apps/mobilizon.nix
{
  app,
  config,
  host,
  inputs,
  lib,
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
    home = "${app.principal.home}/mobilizon";
    package = inputs.${app.mobilizon.input}.packages.${host.system}.default;
    port = 4000;
    user = app.name;
  };

  hostConfig = config;
in
{
  imports = [
    ../postgresql.nix
  ];

  config = {
    services.mobilizon.settings."Mobilizon.Web.Email.Mailer" =
      lib.mkIf (app.mobilizon.mailServer != null)
        {
          adapter = (pkgs.formats.elixirConf { }).lib.mkAtom "Swoosh.Adapters.SMTP";
          relay = app.mobilizon.mailServer;
        };

    o11n.postgresql = {
      databases = {
        ${cfg.database} = { inherit (cfg) user; };
      };
      # Through a bind of /run/postgresql, which postgresql makes anew each time it starts.
      containers = [ cfg.name ];
    };

    services.nginx.virtualHosts = {
      ${cfg.endpoint} =
        let
          proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
        in
        {
          forceSSL = cfg.ssl;
          enableACME = cfg.ssl;

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
            root = "${cfg.package}/lib/mobilizon-${cfg.package.version}/priv/static";
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
        };
    };

    systemd.services = {
      "container@${cfg.name}" = {
        serviceConfig = {
          TimeoutStopSec = 10;
          KillMode = "mixed";
        };
      };
    };

    containers = {
      ${cfg.name} = {
        autoStart = true;
        ephemeral = true;

        bindMounts = {
          "/var/lib/mobilizon" = {
            isReadOnly = false;
            hostPath = cfg.home;
          };
          "/run/postgresql" = {
            isReadOnly = false;
          };
        };

        config =
          let
            postgresqlPackage = hostConfig.services.postgresql.package;
          in
          {
            system = {
              inherit (hostConfig.system) stateVersion;
            };
            users = {
              users.mobilizon = {
                inherit (cfg) uid;
                group = "mobilizon";
              };
              groups.mobilizon.gid = cfg.gid;
            };

            systemd.services.mobilizon-postgresql.enable = lib.mkForce false;

            environment.systemPackages = [ postgresqlPackage ];

            systemd.services.mobilizon = {
              path = [ postgresqlPackage ];
            };

            services.postgresql = {
              enable = lib.mkForce false;
              package = postgresqlPackage;
            };

            # ...
            services.mobilizon =
              let
                elixirConf = pkgs.formats.elixirConf { elixir = cfg.package.elixirPackage; };
              in
              {
                enable = true;
                inherit (cfg) package;
                nginx.enable = false;
                settings.":mobilizon" = {
                  "Mobilizon.Web.Endpoint".http = {
                    inherit (cfg) port;
                    ip = elixirConf.lib.mkRaw ''elem(:inet.parse_address(~c"${cfg.bindAddress}"), 1)'';
                  };
                  "Mobilizon.Storage.Repo" = {
                    inherit (cfg) database;
                    socket_dir = "/run/postgresql";
                    username = cfg.user;
                  };
                  ":instance" = {
                    inherit (cfg) name;
                    hostname = cfg.endpoint;
                  };
                };

              };
          };

      };
    };
  };
}
