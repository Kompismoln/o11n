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
      home = "/var/lib/zitadel";
      masterKeyFile = "/run/secrets/zitadel-masterkey";
      bindAddress = "fd12:3456:7890:1::1";
    };
    system.stateVersion = lib.trivial.release;
  };

  cfg = evalNixosModule [
    ../nixos/zitadel.nix
    baseConfig
  ];

  vhost = cfg.services.nginx.virtualHosts."auth.example.com";
  container = cfg.containers.zitadel;
  containerCfg = container.config;
in
lib.runTests {
  test_zitadel_settings_derived = {
    expr = {
      inherit (cfg.o11n.zitadel.settings)
        Port
        ExternalDomain
        ExternalPort
        ExternalSecure
        ;
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
    expected = "http://[fd12:3456:7890:1::1]:8080";
  };

  test_zitadel_grpc_pass = {
    expr = lib.hasInfix "grpc_pass grpc://[fd12:3456:7890:1::1]:8080;" vhost.locations."/".extraConfig;
    expected = true;
  };

  # ZITADEL always binds all interfaces, so it needs its own network
  # namespace to not collide with other services on `port` -- this is the
  # part that keeps 8080 collision-free without a host-wide port registry.
  test_zitadel_container_private_network = {
    expr = {
      inherit (container) privateNetwork hostAddress6 localAddress6;
    };
    expected = {
      privateNetwork = true;
      hostAddress6 = "fd00::1";
      localAddress6 = "fd12:3456:7890:1::1";
    };
  };

  test_zitadel_container_autostart = {
    expr = {
      inherit (container) autoStart ephemeral;
    };
    expected = {
      autoStart = true;
      ephemeral = true;
    };
  };

  # The master key never touches the store; it has to reach the container
  # by bind mount, at the same path it's configured with.
  test_zitadel_masterkey_bind_mounted = {
    expr = container.bindMounts."/run/secrets/zitadel-masterkey".hostPath;
    expected = "/run/secrets/zitadel-masterkey";
  };

  test_zitadel_service_user = {
    expr = containerCfg.systemd.services.zitadel.serviceConfig.User;
    expected = "zitadel";
  };

  test_zitadel_exec_start_has_masterkey = {
    expr = lib.hasInfix "/run/secrets/zitadel-masterkey" containerCfg.systemd.services.zitadel.serviceConfig.ExecStart;
    expected = true;
  };

  test_zitadel_user_created = {
    expr = containerCfg.users.users.zitadel.isSystemUser;
    expected = true;
  };
}
