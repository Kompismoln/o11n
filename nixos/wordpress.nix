{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.wordpress;
  webserver = config.services.nginx;
  eachApp = lib.filterAttrs (_: appCfg: appCfg.enable) cfg.apps;

  wordpressOpts =
    { config, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this wordpress site";
        name = lib.mkOption {
          description = "instance name";
          type = lib.types.str;
        };
        endpoint = lib.mkOption {
          description = "instance's endpoint";
          type = lib.types.str;
        };
        home = lib.mkOption {
          description = "instance's home";
          type = lib.types.str;
        };
        bindAddress = lib.mkOption {
          description = "unique local address";
          type = lib.types.str;
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
        ssl = lib.mkOption {
          description = "force encrypted connections";
          type = lib.types.bool;
          default = true;
        };
      };
    };

  wpPhp = pkgs.php.buildEnv {
    extensions =
      { enabled, all }:
      with all;
      enabled
      ++ [
        imagick
        memcached
        opcache
      ];
    extraConfig = ''
      memory_limit = 256M
      cgi.fix_pathinfo = 0
    '';
  };

  wpConfig =
    app:
    pkgs.writeText "wp-config-override.php" ''
      <?php
      define( 'WP_DEBUG', false );
      define( 'DB_NAME', '${app.database}' );
      define( 'DB_USER', '${app.name}' );
      define( 'WP_CACHE', true );
      define( 'WP_REDIS_HOST', '${app.bindAddress}' );
    '';
in
{
  options = {
    o11n.wordpress = {
      apps = lib.mkOption {
        type = with lib.types; attrsOf (submodule wordpressOpts);
        default = { };
        description = "Specification of one or more wordpress apps to serve";
      };
    };
  };

  config = lib.mkIf (eachApp != { }) {

    environment.systemPackages = [
      pkgs.wp-cli
    ];

    systemd.tmpfiles.rules = lib.concatMap (app: [
      "d '${app.home}' 0750 ${app.user} ${app.user} - -"
      "L+ ${app.home}/wp-config-override.php - - - - ${wpConfig app}"
    ]) (lib.attrValues eachApp);

    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      lib.nameValuePair app.endpoint {
        forceSSL = app.ssl;
        enableACME = app.ssl;

        root = app.home;

        extraConfig = ''
          index index.php;
        '';

        locations = {
          "/favicon.ico" = {
            priority = 100;
            extraConfig = ''
              log_not_found off;
              access_log off;
            '';
          };

          "/robots.txt" = {
            priority = 100;
            extraConfig = ''
              allow all;
              log_not_found off;
              access_log off;
            '';
          };

          "/" = {
            priority = 200;
            extraConfig = ''
              try_files $uri $uri/ /index.php?$args;
            '';
          };

          "~ \\.php$" = {
            priority = 300;
            extraConfig = ''
              try_files $uri =404;
              fastcgi_split_path_info ^(.+\.php)(/.+)$;
              fastcgi_pass unix:${config.services.phpfpm.pools.${app.name}.socket};
              fastcgi_index index.php;
              include ${config.services.nginx.package}/conf/fastcgi.conf;
              fastcgi_intercept_errors on;
              fastcgi_param HTTP_PROXY "";
              fastcgi_buffer_size 16k;
              fastcgi_buffers 4 16k;
            '';
          };

          "~ /\\." = {
            priority = 800;
            extraConfig = "deny all;";
          };

          "~ \\.(log|sql)$" = {
            priority = 800;
            extraConfig = "deny all;";
          };

          "~* /(?:uploads|files)/.*\\.php$" = {
            priority = 900;
            extraConfig = "deny all;";
          };

          "~* \\.(js|css|png|jpg|jpeg|gif|ico)$" = {
            priority = 1000;
            extraConfig = ''
              expires max;
              log_not_found off;
            '';
          };
        };
      }
    ) eachApp;

    services.phpfpm.pools = lib.mapAttrs (_: app: {
      inherit (app) user;
      group = app.user;
      phpPackage = wpPhp;
      phpOptions = ''
        upload_max_filesize = 16M;
        post_max_size = 16M;
        error_reporting = E_ALL;
        display_errors = Off;
        log_errors = On;
        error_log = ${app.home}/error.log;
        extension=${pkgs.phpExtensions.redis}/lib/php/extensions/redis.so
      '';
      settings = {
        "listen.owner" = webserver.user;
        "listen.group" = webserver.group;
        "pm" = "dynamic";
        "pm.max_children" = 32;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 2;
        "pm.max_spare_servers" = 4;
        "pm.max_requests" = 500;
      };
    }) eachApp;

  };
}
