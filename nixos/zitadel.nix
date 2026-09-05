# nixos/zitadel.nix
#
# A small, self-contained module for ZITADEL, an open-source identity and
# access management platform (OIDC/SAML/MFA). Nixpkgs already ships
# `services.zitadel`, but it is bare-bones: no reverse proxy, and every
# runtime setting has to be assembled by hand. Rather than build on top of
# that module, this one borrows its shape (`settings`/`steps` written out as
# YAML via `pkgs.formats.yaml`, `extraSettingsPaths`/`extraStepsPaths` to
# keep secrets out of the store, `start-from-init` as the one command that
# both bootstraps and runs the service) and adds the nginx vhost ZITADEL
# always needs. Database bootstrapping is intentionally left out here: like
# the rest of o11n, databases and roles are created outside Nix, not by the
# module.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.zitadel;

  settingsFormat = pkgs.formats.yaml { };
  configFile = settingsFormat.generate "zitadel-config.yaml" cfg.settings;
  stepsFile = settingsFormat.generate "zitadel-steps.yaml" cfg.steps;

  # Bracket bare IPv6 addresses for use in a URL, e.g. "::1" -> "[::1]".
  # IPv4 addresses and hostnames are passed through unchanged.
  upstreamHost = if lib.hasInfix ":" cfg.bindAddress then "[${cfg.bindAddress}]" else cfg.bindAddress;
  upstream = "${upstreamHost}:${toString cfg.port}";
in
{
  options.o11n.zitadel = {
    enable = lib.mkEnableOption "ZITADEL, a user and identity access management platform";

    package = lib.mkPackageOption pkgs "zitadel" { default = [ "zitadel" ]; };

    user = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      description = "User to run ZITADEL under.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      description = "Group to run ZITADEL under.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public domain ZITADEL is served on.";
      example = "auth.kompismoln.se";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port ZITADEL listens on, reverse-proxied by nginx.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "::1";
      description = ''
        Address nginx proxies to. ZITADEL itself has no bind-address
        setting of its own and always listens on all interfaces on `port`,
        so this only controls what nginx forwards to: keep it loopback
        unless something other than this host's nginx needs to reach
        ZITADEL directly. Accepts an IPv6 address, e.g. "::1".
      '';
    };

    masterKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing a 32 byte master encryption key for
        ZITADEL, e.g. from `tr -dc A-Za-z0-9 </dev/urandom | head -c32`.
        Keep it out of the Nix store, it must stay stable for the lifetime
        of the instance.
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
      '';
      example = lib.literalExpression ''
        {
          Database.postgres = {
            Host = "localhost";
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
        Extra settings files, layered on top of `settings`. Use this to keep
        secrets such as database passwords out of the Nix store.
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
      description = "Extra steps files, layered on top of `steps`.";
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
        proxyPass = "http://${upstream}";
        recommendedProxySettings = true;
      };
      locations."/" = {
        extraConfig = ''
          grpc_pass grpc://${upstream};
          grpc_set_header Host $host;
          grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          grpc_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };

    systemd.services.zitadel = {
      description = "ZITADEL identity and access management";
      wantedBy = [ "multi-user.target" ];
      after = lib.optional config.services.postgresql.enable "postgresql.service";

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        ExecStart =
          let
            # `start-from-init` runs the setup steps and starts the server
            # in one go; it's safe to run on every boot since ZITADEL
            # tracks which steps are already applied in the database.
            args = lib.cli.toCommandLineShellGNU { } {
              config = cfg.extraSettingsPaths ++ [ configFile ];
              steps = cfg.extraStepsPaths ++ [ stepsFile ];
              masterkeyFile = cfg.masterKeyFile;
              tlsMode = "external";
            };
          in
          "${lib.getExe' cfg.package "zitadel"} start-from-init ${args}";
      };
    };

    users.users.zitadel = lib.mkIf (cfg.user == "zitadel") {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.zitadel = lib.mkIf (cfg.group == "zitadel") { };
  };
}
