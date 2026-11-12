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
  packages = inputs.${app.django.input}.packages.${host.system};

  cfg = {
    inherit (app)
      name
      endpoint
      database
      ssl
      ;
    inherit (app.principal) bindAddress;
    inherit (app.django)
      module
      locationProxy
      trustedOrigins
      timeout
      ;
    home = "${app.principal.home}/django";
    package = packages.django-app;
    scripts = packages.scripts or null;
    worker-package = null;
    secretKeyPath = config.sops.secrets."${app.name}/secret-key".path;
    user = app.name;
    port = 8000;
    locationStatic = "/static/";
    env = { };
    workers = 2;
  };

  envVars = {
    DB_NAME = cfg.database;
    DB_USER = cfg.user;
    DB_HOST = "/run/postgresql";
    DEBUG = "false";
    DJANGO_SETTINGS_MODULE = "${cfg.module}.settings";
    HOST = cfg.endpoint;
    DJANGO_MODE = "main";
    DJANGO_LOG_LEVEL = "WARNING";
    SCHEME = if cfg.ssl then "https" else "http";
    TRUSTED_ORIGINS = builtins.concatStringsSep "," cfg.trustedOrigins;
    SECRET_KEY_FILE = cfg.secretKeyPath;
    STATIC_URL = cfg.locationStatic;
    STATE_DIR = cfg.home;
    STATIC_ROOT = static;
  }
  // cfg.env;

  static = pkgs.runCommand "${cfg.name}-static" { } ''
    export STATIC_ROOT="$out"
    export STATIC_URL="${cfg.locationStatic}"
    export DJANGO_MODE="collectstatic"
    export DJANGO_SETTINGS_MODULE=${cfg.module}.settings
    ${cfg.package}/bin/django-admin collectstatic --no-input
  '';

  wrapBins =
    pkgs: pkg: env:
    let
      wrapperArgs = lib.concatLists (
        lib.mapAttrsToList (name: value: [
          "--set"
          name
          value
        ]) env
      );
    in
    pkgs.symlinkJoin {
      name = "${pkg.name}-wrapped";
      paths = [ pkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];

      postBuild = ''
        for binary in $out/bin/*; do
          wrapProgram "$binary" ${lib.escapeShellArgs wrapperArgs}
        done
      '';
    };

  scripts = lib.optional (cfg.scripts != null) (wrapBins pkgs cfg.scripts envVars);
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

    environment.systemPackages = scripts;

    o11n.postgresql.databases = {
      ${cfg.database} = { inherit (cfg) user; };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -"
    ];

    services.nginx.virtualHosts = {
      ${cfg.endpoint} = {
        forceSSL = cfg.ssl;
        enableACME = cfg.ssl;
        locations =
          lib.optionalAttrs (cfg.locationProxy != "") {
            ${cfg.locationProxy} = {
              recommendedProxySettings = true;
              proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
              extraConfig = ''
                proxy_read_timeout ${toString cfg.timeout}s;
                proxy_connect_timeout ${toString cfg.timeout}s;
              '';
            };
          }
          // lib.optionalAttrs (cfg.locationStatic != "") {
            ${cfg.locationStatic} = {
              alias = "${static}/";
            };
          };
      };
    };

    systemd.services = {

      "${cfg.name}-django" = {
        path = [ config.services.postgresql.package ];
        after = [ "postgresql.target" ];
        requires = [ "postgresql.target" ];
        description = "serve ${cfg.name}";
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${cfg.package}/bin/gunicorn"
            "${cfg.module}.asgi:application"
            "--bind=[${cfg.bindAddress}]:${toString cfg.port}"
            "--timeout=${toString cfg.timeout}"
            "--workers=${toString cfg.workers}"
            "--worker-class=uvicorn.workers.UvicornWorker"
          ];
          User = cfg.user;
          Group = cfg.user;
          Environment = lib.mapAttrsToList (name: value: "${name}=${toString value}") envVars;
        };
        wantedBy = [ "multi-user.target" ];
      };

      "${cfg.name}-django-worker" = lib.mkIf (cfg.worker-package != null) {
        path = [ config.services.postgresql.package ];
        after = [ "postgresql.target" ];
        requires = [ "postgresql.target" ];
        description = "serve ${cfg.name} worker";
        serviceConfig = {
          ExecStart = lib.getExe cfg.worker-package;
          User = cfg.user;
          Group = cfg.user;
          Environment = lib.mapAttrsToList (name: value: "${name}=${toString value}") envVars;
        };
        wantedBy = [ "multi-user.target" ];
      };
    };

  };
}
