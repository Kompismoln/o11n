# nixos/django.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.django;

  eachApp = lib.filterAttrs (_: appCfg: appCfg.enable) cfg.apps;

  djangoOpts =
    { config, ... }:
    {
      options = {
        enable = lib.mkEnableOption "django";
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
        secretKeyPath = lib.mkOption {
          description = "path to secret key file";
          type = lib.types.str;
        };
        bindAddress = lib.mkOption {
          description = "address this app should bind to";
          type = lib.types.str;
        };
        scripts = lib.mkOption {
          description = "optional scripts package";
          default = null;
          type = with lib.types; nullOr package;
        };
        port = lib.mkOption {
          description = "port";
          type = lib.types.port;
          default = 8000;
        };
        ssl = lib.mkOption {
          description = "force encrypted connections";
          type = lib.types.bool;
          default = true;
        };
        module = lib.mkOption {
          description = "django module";
          type = lib.types.str;
          default = "${config.name}.django";
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
        locationStatic = lib.mkOption {
          description = "Location pattern for static files, empty string -> no static";
          type = lib.types.str;
          default = "/static/";
        };
        locationProxy = lib.mkOption {
          description = "Location pattern for proxy to django, empty string -> no proxy";
          type = lib.types.str;
          example = "~ ^/(api|admin)";
          default = "/";
        };
        trustedOrigins = lib.mkOption {
          description = "Origins that this backend trusts";
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        env = lib.mkOption {
          description = "Variables to add to environment.";
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
        worker-package = lib.mkOption {
          description = "Optional worker running besides django";
          type = lib.types.nullOr lib.types.package;
          default = null;
        };
        workers = lib.mkOption {
          description = "The number of worker processes for handling requests.";
          type = lib.types.int;
          default = 2;
        };
        timeout = lib.mkOption {
          description = "Workers silent for more than this many seconds are killed and restarted.";
          type = lib.types.int;
          example = 180;
          default = 30;
        };
      };
    };

  envs = lib.mapAttrs (
    _: app:
    {
      DB_NAME = app.database;
      DB_USER = app.user;
      DB_HOST = "/run/postgresql";
      DEBUG = "false";
      DJANGO_SETTINGS_MODULE = "${app.module}.settings";
      HOST = app.endpoint;
      DJANGO_MODE = "main";
      DJANGO_LOG_LEVEL = "WARNING";
      SCHEME = if app.ssl then "https" else "http";
      TRUSTED_ORIGINS = builtins.concatStringsSep "," app.trustedOrigins;
      SECRET_KEY_FILE = app.secretKeyPath;
      STATIC_URL = app.locationStatic;
      STATE_DIR = app.home;
      STATIC_ROOT = statics.${app.name};
    }
    // app.env
  ) eachApp;

  mkCollectStatic =
    _: app:
    pkgs.runCommand "${app.name}-static" { } ''
      export STATIC_ROOT="$out"
      export STATIC_URL="${app.locationStatic}"
      export DJANGO_MODE="collectstatic"
      export DJANGO_SETTINGS_MODULE=${app.module}.settings
      ${app.package}/bin/django-admin collectstatic --no-input
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

  statics = lib.mapAttrs mkCollectStatic eachApp;

  scripts = lib.mapAttrs (_: app: wrapBins pkgs app.scripts envs.${app.name}) (
    lib.filterAttrs (_: app: app.scripts != null) eachApp
  );
in
{

  options.o11n.django = {
    apps = lib.mkOption {
      type = with lib.types; attrsOf (submodule djangoOpts);
      default = { };
      description = "Definition of per-domain Django apps to serve.";
    };
  };

  config = lib.mkIf (eachApp != { }) {
    environment.systemPackages = lib.attrValues scripts;

    systemd.tmpfiles.rules = lib.concatMap (app: [
      "d '${app.home}' 0750 ${app.user} ${app.user} - -"
    ]) (lib.attrValues eachApp);

    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      lib.nameValuePair app.endpoint {
        forceSSL = app.ssl;
        enableACME = app.ssl;
        locations =
          lib.optionalAttrs (app.locationProxy != "") {
            ${app.locationProxy} = {
              recommendedProxySettings = true;
              proxyPass = "http://[${app.bindAddress}]:${toString app.port}";
              extraConfig = ''
                proxy_read_timeout ${toString app.timeout}s;
                proxy_connect_timeout ${toString app.timeout}s;
              '';
            };
          }
          // lib.optionalAttrs (app.locationStatic != "") {
            ${app.locationStatic} = {
              alias = "${statics.${app.name}}/";
            };
          };
      }
    ) eachApp;

    systemd.services = lib.concatMapAttrs (_: app: {

      "${app.name}-django" = {
        path = [ pkgs.postgresql ];
        description = "serve ${app.name}";
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${app.package}/bin/gunicorn"
            "${app.module}.asgi:application"
            "--bind=[${app.bindAddress}]:${toString app.port}"
            "--timeout=${toString app.timeout}"
            "--workers=${toString app.workers}"
            "--worker-class=uvicorn.workers.UvicornWorker"
          ];
          User = app.user;
          Group = app.user;
          Environment = lib.mapAttrsToList (name: value: "${name}=${toString value}") envs.${app.name};
        };
        wantedBy = [ "multi-user.target" ];
      };

      "${app.name}-django-worker" = lib.mkIf (app.worker-package != null) {
        path = [ pkgs.postgresql ];
        description = "serve ${app.name} worker";
        serviceConfig = {
          ExecStart = lib.getExe app.worker-package;
          User = app.user;
          Group = app.user;
          Environment = lib.mapAttrsToList (name: value: "${name}=${toString value}") envs.${app.name};
        };
        wantedBy = [ "multi-user.target" ];
      };
    }

    ) eachApp;

  };
}
