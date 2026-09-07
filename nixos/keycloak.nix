# nixos/keycloak.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.keycloak;
in
{
  options.o11n.keycloak = {
    enable = lib.mkEnableOption "keycloak";

    package = lib.mkPackageOption pkgs "zitadel" { default = [ "zitadel" ]; };

    user = lib.mkOption {
      type = lib.types.str;
      default = "keycloak";
      description = "User to run keycloak under";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "keycloak";
      description = "Group to run keycloak under";
    };

    home = lib.mkOption {
      description = "State directory";
      type = lib.types.str;
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public domain keycloak is served on.";
      example = "auth.kompismoln.se";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv6 address service is bound to";
      example = "fd12:3456:7890:1::1";
    };
  };

  config = {

    services.nginx.virtualHosts.${cfg.endpoint} = {
      forceSSL = true;
      enableACME = true;
      extraConfig = ''
        proxy_buffer_size 32k;
        proxy_buffers 4 32k;
        proxy_busy_buffers_size 32k;
      '';
      locations."/" = {
        recommendedProxySettings = true;
        proxyPass = "http://[${cfg.bindAddress}]:${toString cfg.port}";
      };
    };

    services.keycloak = {
      enable = true;
      settings = {
        hostname = cfg.endpoint;
        http-port = cfg.port;
        http-host = cfg.bindAddress;
        http-enabled = true;
        proxy-headers = "xforwarded";
      };
      database.host = "/run/postgresql";
      plugins = [
        pkgs.keycloak.plugins.junixsocket-common
        pkgs.keycloak.plugins.junixsocket-native-common
      ];
      initialAdminPassword = "_";
    };

  };
}
