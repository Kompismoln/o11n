{
  app,
  config,
  lib,
  pkgs,
  ...
}:

let
  webserver = config.services.nginx;
  cfg = {
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
        redis
      ];
    extraConfig = ''
      memory_limit = 256M
      cgi.fix_pathinfo = 0
    '';
  };

  wpConfig = pkgs.writeText "wp-config-override.php" ''
    <?php
    define( 'WP_DEBUG', false );
    define( 'DB_NAME', '${cfg.database}' );
    define( 'DB_USER', '${cfg.name}' );
    define( 'WP_CACHE', true );
    define( 'WP_REDIS_HOST', '${cfg.bindAddress}' );
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

    o11n.mysql.databases = {
      ${cfg.database} = { inherit (cfg) user; };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.home}' 0750 ${cfg.user} ${cfg.user} - -"
      "L+ ${cfg.home}/wp-config-override.php - - - - ${wpConfig}"
    ];

    # Policy: a failed login is a POST to wp-login.php that it answers with anything but a redirect, as the form again
    # or a 503 under load, and a POST to xmlrpc.php, which nginx denies, is one tried; so is either at an altpoint,
    # which only redirects, as no browser posts there.
    # Dependency: nixos/nginx.nix logs each request as JSON with these fields first, in this order.
    services.fail2ban.jails."wordpress-${cfg.name}" = {
      filter.Definition.failregex =
        let
          post =
            status: path:
            ''^\{"time_iso8601": "[^"]*", "status": "${status}", "remote_addr": "<ADDR>", "remote_user": "[^"]*", "request_method": "POST", "request_uri": "/+${path}(?:\?[^"]*)?", "server_protocol": "[^"]*", "host": "(?:${hosts})",'';
          hosts = lib.concatMapStringsSep "|" lib.escapeRegex ([ cfg.endpoint ] ++ app.altpoints or [ ]);
        in
        lib.concatStringsSep "\n  " [
          (post "(?!302)\\d+" "wp-login\\.php")
          (post "\\d+" "xmlrpc\\.php")
        ];
      settings = {
        backend = "auto";
        logpath = "/var/log/nginx/access.log";
        port = "http,https";
        maxretry = 5;
        findtime = "1h";
      };
    };

    services.nginx.virtualHosts = {
      ${cfg.endpoint} = {
        forceSSL = cfg.ssl;
        enableACME = cfg.ssl;

        root = cfg.home;

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
              fastcgi_pass unix:${config.services.phpfpm.pools.${cfg.name}.socket};
              fastcgi_index index.php;
              include ${config.services.nginx.package}/conf/fastcgi.conf;
              fastcgi_intercept_errors on;
              fastcgi_param HTTP_PROXY "";
              fastcgi_buffer_size 16k;
              fastcgi_buffers 4 16k;
            '';
          };

          "= /xmlrpc.php" = {
            priority = 100;
            extraConfig = "deny all;";
          };

          # Fact: nginx takes the first regex location that matches, so a deny of PHP comes before `~ \.php$`.
          "~ /\\." = {
            priority = 250;
            extraConfig = "deny all;";
          };

          "~ \\.(log|sql)$" = {
            priority = 250;
            extraConfig = "deny all;";
          };

          "~* /(?:uploads|files)/.*\\.php$" = {
            priority = 250;
            extraConfig = "deny all;";
          };

          # Policy: PHP that WordPress only includes, which fails when requested on its own.
          "~ ^/(?:wp-config-sample\\.php$|wp-admin/includes/|wp-includes/(?:[^/]+\\.php$|theme-compat/)|wp-content/themes/.*\\.php$)" =
            {
              priority = 250;
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
      };
    };

    services.phpfpm.pools = {
      ${cfg.name} = {
        inherit (cfg) user;
        group = cfg.user;
        phpPackage = wpPhp;
        phpOptions = ''
          upload_max_filesize = 16M;
          post_max_size = 16M;
          error_reporting = E_ALL;
          display_errors = Off;
          log_errors = On;
          error_log = ${cfg.home}/error.log;
        ''
        # Dependency: nixos/org/mail.nix gives a principal that sends an msmtp account named by its id, which keeps the
        # From of a principal that sends as others too, and the mail server holds the envelope to it as to From.
        + lib.optionalString app.principal.mail.send ''
          sendmail_path = "${pkgs.msmtp}/bin/msmtp -C /etc/msmtprc -a ${app.handle} -t${
            lib.optionalString (app.principal.mail.sendAs != [ ]) " --read-envelope-from"
          }"
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
      };
    };

  };
}
