# nixos/apps/django.nix
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

  eachApp.${app.name} = {
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
  imports = [
    ../postgresql.nix
  ];

  config = {
    sops.secrets."${app.name}/secret-key" = {
      inherit (app.secrets) sopsFile;
      owner = app.name;
      group = app.name;
    };

    environment.systemPackages = lib.attrValues scripts;

    o11n.postgresql.databases = lib.mapAttrs' (
      _: app: lib.nameValuePair app.database { inherit (app) user; }
    ) eachApp;

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
        path = [ config.services.postgresql.package ];
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
        path = [ config.services.postgresql.package ];
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
