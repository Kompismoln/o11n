# nixos/zitadel.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.zitadel;
  hostConfig = config;

  settingsFormat = pkgs.formats.yaml { };
  configFile = settingsFormat.generate "zitadel-config.yaml" cfg.settings;
  stepsFile = settingsFormat.generate "zitadel-steps.yaml" cfg.steps;

  secretPaths = map toString (cfg.extraSettingsPaths ++ cfg.extraStepsPaths ++ [ cfg.masterKeyFile ]);

in
{
  options.o11n.zitadel = {
    enable = lib.mkEnableOption "ZITADEL, a user and identity access management platform";

    package = lib.mkPackageOption pkgs "zitadel" { default = [ "zitadel" ]; };

    user = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      description = "User to run ZITADEL under, inside its container.";
    };

    home = lib.mkOption {
      description = "State directory";
      type = lib.types.str;
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      description = "Group to run ZITADEL under, inside its container.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      description = "host user id for container mirroring";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      description = "group id for container mirroring";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public domain ZITADEL is served on.";
      example = "auth.kompismoln.se";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv6 address for the host side of the container's veth pair.";
      example = "fd12:3456:7890:1::1";
    };

    masterKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing a 32 byte master encryption key for
        ZITADEL, e.g. from `tr -dc A-Za-z0-9 </dev/urandom | head -c32`.
      '';
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        Contents of the runtime configuration file. See
        <https://zitadel.com/docs/self-hosting/manage/configure> for
        details. `Port`, `ExternalDomain`, `ExternalPort` and
        `ExternalSecure` are derived from the options above and don't need
        to be repeated here.

        Since ZITADEL runs in its own network namespace, `localhost` here
        means the container, not the host: point `Database.postgres.Host`
        at `hostAddress6` (and make sure Postgres accepts connections from
        it) rather than at a Unix socket or `localhost`.
      '';
      example = lib.literalExpression ''
        {
          Database.postgres = {
            Host = "fd12:3456:7890:1::1"; # hostAddress6
            Database = "zitadel";
            User.Username = "zitadel";
            Admin.Username = "zitadel";
          };
        }
      '';
    };

    extraSettingsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Extra settings files, layered on top of `settings`. Use this to
        keep secrets such as database passwords out of the Nix store.
        Bind-mounted into the container at the same path.
      '';
    };

    steps = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        Contents of the setup steps file, e.g. the declarative first
        instance/admin user. See
        <https://zitadel.com/docs/self-hosting/manage/configure>.
      '';
      example = lib.literalExpression ''
        {
          FirstInstance.Org.Human = {
            UserName = "admin";
            Email.Address = "admin@kompismoln.se";
          };
        }
      '';
    };

    extraStepsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Extra steps files, layered on top of `steps`. Bind-mounted into the
        container at the same path.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    o11n.zitadel.settings = {
      Port = cfg.port;
      ExternalDomain = cfg.endpoint;
      ExternalPort = 443;
      ExternalSecure = true;
    };

    services.nginx.virtualHosts.${cfg.endpoint} = {
      forceSSL = true;
      enableACME = true;
      http2 = true;

      # The login UI is plain HTTP(S); everything else (console, APIs) is
      # served over gRPC and needs `grpc_pass`, not `proxy_pass`.
      locations."/ui/v2/login" = {
        proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
        recommendedProxySettings = true;
      };
      locations."/" = {
        extraConfig = ''
          grpc_pass grpc://[${cfg.bindAddress}]:${toString cfg.port};
          grpc_set_header Host $host;
          grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          grpc_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };

    systemd.services."container@zitadel" = {
      # The container's own systemd doesn't know about the host's
      # postgresql.service, so make sure it's up before the container
      # starts (relevant when Database.postgres.Host points at this host).
      after = lib.optional config.services.postgresql.enable "postgresql.service";
      serviceConfig = {
        TimeoutStopSec = 10;
        KillMode = "mixed";
      };
    };

    containers.zitadel = {
      autoStart = true;
      ephemeral = true;
      privateNetwork = true;
      localAddress6 = cfg.bindAddress;
      hostAddress6 = "fd00::1";

      # Secrets live outside the Nix store on the host (an age/sops secret,
      # typically); bind-mount each one into the container at the same
      # path so `masterKeyFile`/`extraSettingsPaths`/`extraStepsPaths`
      # don't need separate in-container paths.
      bindMounts =
        let
          bindMountsSecrets = lib.genAttrs secretPaths (path: {
            hostPath = path;
            isReadOnly = true;
          });
        in
        bindMountsSecrets
        // {
          ${cfg.home} = {
            hostPath = cfg.home;
            isReadOnly = false;
          };
        };

      config = {
        system.stateVersion = hostConfig.system.stateVersion;

        users.users.${cfg.user} = {
          inherit (cfg) uid group;
          isSystemUser = true;
        };
        users.groups.${cfg.group} = {
          inherit (cfg) gid;
        };

        systemd.services.zitadel = {
          description = "ZITADEL identity and access management";
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = cfg.group;
            ExecStart =
              let
                args = lib.cli.toCommandLineShellGNU { } {
                  config = cfg.extraSettingsPaths ++ [ configFile ];
                  steps = cfg.extraStepsPaths ++ [ stepsFile ];
                  masterkeyFile = cfg.masterKeyFile;
                  tlsMode = "external";
                };
              in
              "${lib.getExe' cfg.package "zitadel"} start-from-setup ${args}";
          };
        };
      };
    };
  };
}
