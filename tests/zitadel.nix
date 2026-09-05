# tests/zitadel.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) evalNixosModule;

  baseConfig = {
    o11n.zitadel = {
      enable = true;
      endpoint = "auth.example.com";
      masterKeyFile = "/run/secrets/zitadel-masterkey";
    };
    system.stateVersion = lib.trivial.release;
  };

  eval =
    extraConfig:
    evalNixosModule [
      ../nixos/zitadel.nix
      baseConfig
      extraConfig
    ];

  cfg = eval { };
  cfgIPv6 = eval { o11n.zitadel.bindAddress = "::1"; };

  vhost = cfg.services.nginx.virtualHosts."auth.example.com";
  vhostIPv6 = cfgIPv6.services.nginx.virtualHosts."auth.example.com";
in
lib.runTests {
  test_zitadel_settings_derived = {
    expr = {
      inherit (cfg.o11n.zitadel.settings) Port ExternalDomain ExternalPort ExternalSecure;
    };
    expected = {
      Port = 8080;
      ExternalDomain = "auth.example.com";
      ExternalPort = 443;
      ExternalSecure = true;
    };
  };

  test_zitadel_vhost_ssl = {
    expr = {
      inherit (vhost) forceSSL enableACME;
    };
    expected = {
      forceSSL = true;
      enableACME = true;
    };
  };

  test_zitadel_login_proxy_pass = {
    expr = vhost.locations."/ui/v2/login".proxyPass;
    expected = "http://127.0.0.1:8080";
  };

  test_zitadel_grpc_pass = {
    expr = lib.hasInfix "grpc_pass grpc://127.0.0.1:8080;" vhost.locations."/".extraConfig;
    expected = true;
  };

  test_zitadel_login_proxy_pass_ipv6 = {
    expr = vhostIPv6.locations."/ui/v2/login".proxyPass;
    expected = "http://[::1]:8080";
  };

  test_zitadel_grpc_pass_ipv6 = {
    expr = lib.hasInfix "grpc_pass grpc://[::1]:8080;" vhostIPv6.locations."/".extraConfig;
    expected = true;
  };

  test_zitadel_service_user = {
    expr = cfg.systemd.services.zitadel.serviceConfig.User;
    expected = "zitadel";
  };

  test_zitadel_exec_start_has_masterkey = {
    expr = lib.hasInfix "/run/secrets/zitadel-masterkey" cfg.systemd.services.zitadel.serviceConfig.ExecStart;
    expected = true;
  };

  test_zitadel_user_created = {
    expr = cfg.users.users.zitadel.isSystemUser;
    expected = true;
  };
}
