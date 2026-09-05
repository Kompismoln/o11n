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
#
# ZITADEL runs in a private-networked nixos-container rather than directly
# on the host, and that's not just following the pattern the other o11n web
# apps use (their containers actually share the host's network namespace,
# see e.g. mobilizon.nix/opencloud.nix -- they're containerized for
# filesystem/dependency isolation, not networking). ZITADEL has no
# bind-address setting of its own: it always listens on all interfaces on
# `port`, which is fine behind a reverse proxy but means it can't take part
# in o11n's usual way of avoiding port collisions (every entity gets its
# own address and binds *that*, so everyone can default to the same port).
# A wildcard bind claims the port on every address on the host, so it would
# collide with any other service using it, and there's no per-app port
# registry to route around that by hand.
#
# The fix has to be network-namespace isolation, since ZITADEL can't be
# told to bind narrower. A bare `PrivateNetwork=` on the systemd service
# would do the isolation, but it also cuts off all connectivity -- nginx
# couldn't reach it either -- and bridging that back over a veth by hand
# means re-implementing, unit by unit, exactly what systemd-nspawn already
# does. nixos-container *is* that: it's systemd's own container tooling
# (systemd-nspawn), not a separate, heavier technology, so reaching for
# `containers.zitadel` here is the systemd-native answer, just via the
# tested abstraction instead of hand-rolled `ip netns`/veth plumbing.
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

  # The container's own address, reachable from the host over the veth pair;
  # what nginx proxies to. Always IPv6, so always bracket for use in a URL.
  upstream = "[${cfg.localAddress6}]:${toString cfg.port}";

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

    group = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      description = "Group to run ZITADEL under, inside its container.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public domain ZITADEL is served on.";
      example = "auth.kompismoln.se";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port ZITADEL listens on inside its container, reverse-proxied by
        nginx on the host. Since the container has its own network
        namespace, this can safely stay at ZITADEL's own unsurprising
        default regardless of what else runs on the host.
      '';
    };

    hostAddress6 = lib.mkOption {
      type = lib.types.str;
      description = "IPv6 address for the host side of the container's veth pair.";
      example = "fd12:3456:7890:1::1";
    };

    localAddress6 = lib.mkOption {
      type = lib.types.str;
      description = ''
        IPv6 address for the container, i.e. ZITADEL itself. This is what
        nginx proxies to, and (along with `hostAddress6`) is what keeps
        this instance from colliding with anything else on `port`: give it
        this entity's own unique address, same as o11n's other apps.
      '';
      example = "fd12:3456:7890:1::2";
    };

    masterKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing a 32 byte master encryption key for
        ZITADEL, e.g. from `tr -dc A-Za-z0-9 </dev/urandom | head -c32`.
        Keep it out of the Nix store, it must stay stable for the lifetime
        of the instance. Bind-mounted into the container at the same path.
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
      inherit (cfg) hostAddress6 localAddress6;

      # Secrets live outside the Nix store on the host (an age/sops secret,
      # typically); bind-mount each one into the container at the same
      # path so `masterKeyFile`/`extraSettingsPaths`/`extraStepsPaths`
      # don't need separate in-container paths.
      bindMounts = lib.genAttrs secretPaths (path: {
        hostPath = path;
        isReadOnly = true;
      });

      config = {
        system.stateVersion = hostConfig.system.stateVersion;

        users.users.${cfg.user} = lib.mkIf (cfg.user == "zitadel") {
          isSystemUser = true;
          group = cfg.group;
        };
        users.groups.${cfg.group} = lib.mkIf (cfg.group == "zitadel") { };

        systemd.services.zitadel = {
          description = "ZITADEL identity and access management";
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = cfg.group;
            Restart = "on-failure";
            ExecStart =
              let
                # `start-from-init` runs the setup steps and starts the
                # server in one go; it's safe to run on every boot since
                # ZITADEL tracks which steps are already applied in the
                # database.
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
      };
    };
  };
}
