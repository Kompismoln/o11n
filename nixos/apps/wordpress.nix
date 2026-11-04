# nixos/apps/wordpress.nix
{
  app,
  config,
  lib,
  pkgs,
  ...
}:

let
  webserver = config.services.nginx;
  eachApp.${app.name} = {
    inherit (app)
      name
      endpoint
      database
      ssl
      ;
    inherit (app.principal) bindAddress;
    home = "${app.principal.home}/wordpress";
    user = app.name;
  };

  wpPhp = pkgs.php.buildEnv {
    extensions =
      { enabled, all }:
      with all;
      enabled
      ++ [
        imagick
        memcached
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
  imports = [
    ../mysql.nix
    ../redis.nix
  ];

  config = {
    o11n.redis.servers.${app.name} = {
      enable = true;
      user = app.name;
      home = "${app.principal.home}/redis";
      bind = app.principal.bindAddress;
      settings."protected-mode" = "no";
    };

    environment.systemPackages = [
      pkgs.wp-cli
    ];

    o11n.mysql.databases = lib.mapAttrs' (
      _: app: lib.nameValuePair app.database { inherit (app) user; }
    ) eachApp;

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
