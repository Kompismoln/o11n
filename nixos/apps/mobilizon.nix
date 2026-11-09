{
  app,
  config,
  host,
  inputs,
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
    home = "${app.principal.home}/mobilizon";
    inherit (app.mobilizon) from;
    package = inputs.${app.mobilizon.input}.packages.${host.system}.default;
    port = 4000;
    user = app.name;
  };

  hostConfig = config;
  inherit (app.principal) mail;
in
{
  imports = [
    ../postgresql.nix
  ];

  config = {
    assertions = lib.optional mail.send {
      assertion =
        lib.elem (lib.toLower cfg.from) (map lib.toLower ([ mail.address ] ++ mail.sendAs))
        || lib.elem (lib.toLower "@${lib.last (lib.splitString "@" cfg.from)}") (
          map lib.toLower mail.sendAs
        );
      message = "${app.handle}'s mobilizon is from ${cfg.from}, which it doesn't send as: set mobilizon.from, or add it to principal.mail.sendAs.";
    };

    # Dependency: nixos/org/mail.nix declares the password of a principal that sends.
    sops.templates."${cfg.name}-mail.env" = lib.mkIf mail.send {
      content = "O11N_MAIL_PASSWORD=${config.sops.placeholder."${cfg.name}/mail"}\n";
      owner = cfg.user;
    };

    o11n.postgresql = {
      databases = {
        ${cfg.database} = { inherit (cfg) user; };
      };
      # Fact: the container reaches it through a bind of /run/postgresql, which postgresql makes anew each time it
      # starts.
      containers = [ cfg.name ];
    };

    # Policy: a GET for a profile or a webfinger that it answers as not found is a name tried; a client that tries
    # many in an hour is enumerating the instance's users.
    # Dependency: nixos/nginx.nix logs each request as JSON with these fields first, in this order.
    services.fail2ban.jails."mobilizon-${cfg.name}" = {
      filter.Definition.failregex =
        let
          notFound =
            path:
            ''^\{"time_iso8601": "[^"]*", "status": "404", "remote_addr": "<ADDR>", "remote_user": "[^"]*", "request_method": "(?:GET|HEAD)", "request_uri": "${path}", "server_protocol": "[^"]*", "host": "${lib.escapeRegex cfg.endpoint}",'';
        in
        lib.concatStringsSep "\n  " [
          (notFound "/@[^\"]*")
          (notFound "/\\.well-known/webfinger\\?[^\"]*")
        ];
      settings = {
        backend = "auto";
        logpath = "/var/log/nginx/access.log";
        port = "http,https";
        maxretry = 10;
        findtime = "1h";
      };
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
            proxyWebsockets = true;
            recommendedProxySettings = lib.mkDefault true;
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

    # Fact: nspawn refuses to start a container whose bind's host path is missing.
    systemd.tmpfiles.rules = [ "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -" ];

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
        }
        // lib.optionalAttrs mail.send {
          "/run/o11n-mail.env" = {
            hostPath = config.sops.templates."${cfg.name}-mail.env".path;
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

            # Policy: no Erlang distribution, which would listen on every network the host has, with epmd, for
            # whoever has the cookie; it stops on SIGTERM, and mobilizon_ctl evaluates rather than calls the node.
            systemd.services.mobilizon = {
              path = [ postgresqlPackage ];
              environment.RELEASE_DISTRIBUTION = "none";
              serviceConfig = {
                EnvironmentFile = lib.mkIf mail.send "/run/o11n-mail.env";
                ExecStop = lib.mkForce "";
                # Policy: mobilizon logs warnings and errors alone, and to the console too, which nspawn writes to
                # container@<app>'s journal on the host, where they outlive the container and the logs service reads
                # them.
                StandardOutput = "journal+console";
                StandardError = "journal+console";
              };
            };
            environment.variables.MOBILIZON_CTL_RPC_DISABLED = "true";

            services.postgresql = {
              enable = lib.mkForce false;
              package = postgresqlPackage;
            };

            services.mobilizon =
              let
                elixirConf = pkgs.formats.elixirConf { elixir = cfg.package.elixirPackage; };
              in
              {
                enable = true;
                inherit (cfg) package;
                nginx.enable = false;
                settings.":logger".":level" = elixirConf.lib.mkAtom ":warning";
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
                  }
                  // lib.optionalAttrs mail.send {
                    email_from = cfg.from;
                    email_reply_to = cfg.from;
                  };
                }
                // lib.optionalAttrs mail.send {
                  # Dependency: nixos/services/mailserver.nix serves submission as mail.<endpoint>.
                  "Mobilizon.Web.Email.Mailer" = rec {
                    adapter = elixirConf.lib.mkAtom "Swoosh.Adapters.SMTP";
                    relay = "mail.${org.mailserver.endpoint}";
                    port = 587;
                    username = mail.address;
                    password = elixirConf.lib.mkGetEnv { envVariable = "O11N_MAIL_PASSWORD"; };
                    tls = elixirConf.lib.mkAtom ":always";
                    # Quirk: gen_smtp's default tls_options have no cacerts, so OTP's default verify_peer refuses them
                    # before the handshake, and gen_smtp says QUIT in plain text, which postfix logs as "wrong version
                    # number".
                    # Fact: a raw value that ends in a newline ends the expression before the next key.
                    tls_options = elixirConf.lib.mkRaw "[verify: :verify_peer, cacerts: :public_key.cacerts_get(), server_name_indication: ~c\"${relay}\", depth: 99]";
                    auth = elixirConf.lib.mkAtom ":always";
                  };
                };
              };
          };

      };
    };
  };
}
