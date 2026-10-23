{
  lib,
  evalNixosModule,
}:
let
  baseConfig = {
    o11n.keycloak = {
      enable = true;
      endpoint = "auth.example.com";
      home = "/var/lib/keycloak";
      bindAddress = "fd12:3456:7890:1::1";
    };
    system.stateVersion = lib.trivial.release;
  };

  cfg = evalNixosModule [
    ../../nixos/keycloak.nix
    baseConfig
    {
      options.o11n.preserve.databases = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
      };
    }
  ];

  vhost = cfg.services.nginx.virtualHosts."auth.example.com";
in
{

  test_keycloak_settings_derived = {
    expr = {
      inherit (cfg.services.keycloak.settings)
        hostname
        http-host
        http-port
        http-enabled
        proxy-headers
        ;
    };
    expected = {
      hostname = "auth.example.com";
      http-host = "fd12:3456:7890:1::1";
      http-port = 8080;
      http-enabled = true;
      proxy-headers = "xforwarded";
    };
  };

  test_keycloak_vhost_ssl = {
    expr = {
      inherit (vhost) forceSSL enableACME;
    };
    expected = {
      forceSSL = true;
      enableACME = true;
    };
  };

  test_keycloak_login_proxy_pass = {
    expr = vhost.locations."/".proxyPass;
    expected = "http://[fd12:3456:7890:1::1]:8080";
  };

  test_keycloak_database = {
    expr = cfg.o11n.postgresql.databases.keycloak.user;
    expected = "keycloak";
  };

}
