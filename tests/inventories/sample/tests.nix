# tests/inventories/sample/tests.nix
{ lib, outputs }:
let
  inherit (outputs.nixosConfigurations) gw web;

  onHosts = f: {
    gw = f gw.config;
    web = f web.config;
  };

  wg0 = config: config.systemd.network.netdevs."20-wg0";
in
{
  test_nixos_hosts = {
    expr = lib.attrNames outputs.nixosConfigurations;
    expected = [
      "gw"
      "web"
    ];
  };

  # Each side of wg0 holds the other's public key, as id-entities.sh wrote it.
  test_wg0_peers = {
    expr = onHosts (config: (wg0 config).wireguardPeers);
    expected = {
      gw = [
        {
          PublicKey = builtins.readFile ./public-keys/host-web-wg0-key.pub;
          AllowedIPs = [
            "fd12:3456:7890:0000::0002/128"
            "10.0.0.2/32"
          ];
          PersistentKeepalive = 25;
        }
      ];
      web = [
        {
          PublicKey = builtins.readFile ./public-keys/host-gw-wg0-key.pub;
          AllowedIPs = [
            "fd12:3456:7890:0000::/64"
            "10.0.0.0/24"
          ];
          Endpoint = "gw.example.com:51820";
        }
      ];
    };
  };

  test_wg0_addresses = {
    expr = onHosts (config: config.systemd.network.networks."30-wg0".address);
    expected = {
      gw = [
        "fd12:3456:7890:0000::0001/64"
        "10.0.0.1/24"
      ];
      web = [
        "fd12:3456:7890:0000::0002/64"
        "10.0.0.2/24"
      ];
    };
  };

  # Only the gateway listens, forwards and answers DNS for the vpn.
  test_wg0_gateway = {
    expr = onHosts (config: {
      listenPort = (wg0 config).wireguardConfig.ListenPort or null;
      allowedUDPPorts = config.networking.firewall.allowedUDPPorts;
      forwarding = config.boot.kernel.sysctl."net.ipv4.ip_forward" or 0;
      dns = config.services.kresd.enable;
    });
    expected = {
      gw = {
        listenPort = 51820;
        allowedUDPPorts = [ 51820 ];
        forwarding = 1;
        dns = true;
      };
      web = {
        listenPort = null;
        allowedUDPPorts = [ ];
        forwarding = 0;
        dns = false;
      };
    };
  };

  test_wg0_dns_hints = {
    expr = lib.filter (lib.hasPrefix "hints[") (
      lib.splitString "\n" gw.config.services.kresd.extraConfig
    );
    expected = [
      "hints['gw.sample'] = 'fd12:3456:7890:0000::0001'"
      "hints['gw.sample'] = '10.0.0.1'"
      "hints['web.sample'] = 'fd12:3456:7890:0000::0002'"
      "hints['web.sample'] = '10.0.0.2'"
    ];
  };

  # The host's users and its roles' services, with uids from their class and id.
  test_principal_uids = {
    expr = onHosts (
      config:
      lib.mapAttrs (_: user: user.uid) (
        lib.filterAttrs (
          _: user: user.uid != null && user.uid >= 1000 && user.uid < 5000
        ) config.users.users
      )
    );
    expected =
      let
        uids = {
          admin = 1000;
          locksmith = 2000;
          reverse-tunnel = 2001;
          nix-build = 2002;
          nix-switch = 2003;
          nix-push = 2004;
          egress-proxy = 2007;
        };
      in
      {
        gw = uids;
        web = uids;
      };
  };

  # Every secret a host needs, and the file in enc/ it is read from.
  test_secrets = {
    expr = onHosts (config: lib.mapAttrs (_: secret: baseNameOf secret.sopsFile) config.sops.secrets);
    expected = {
      gw = {
        "admin/mail" = "user-admin.yaml";
        "admin/passwd-sha512" = "user-admin.yaml";
        "reverse-tunnel/passwd-sha512" = "service-reverse-tunnel.yaml";
        "wg0-key" = "host-gw.yaml";
      };
      web = {
        "admin/mail" = "user-admin.yaml";
        "admin/passwd-sha512" = "user-admin.yaml";
        "reverse-tunnel/passwd-sha512" = "service-reverse-tunnel.yaml";
        "wg0-key" = "host-web.yaml";
      };
    };
  };

  # Only gw is in rescue mode.
  test_rescue = {
    expr = onHosts (config: {
      passwordFile = lib.mapNullable baseNameOf config.users.users.root.hashedPasswordFile;
      keyFiles = map baseNameOf config.users.users.root.openssh.authorizedKeys.keyFiles;
    });
    expected = {
      gw = {
        passwordFile = "service-rescue-passwd.sha512";
        keyFiles = [ "service-rescue-ssh-key.pub" ];
      };
      web = {
        passwordFile = null;
        keyFiles = [ ];
      };
    };
  };

  # gw is the mailserver host, so only web relays mail through msmtp.
  test_sendmail = {
    expr = onHosts (config: config.programs.msmtp.enable);
    expected = {
      gw = false;
      web = true;
    };
  };

  test_nix_serve_trusted = {
    expr = onHosts (
      config:
      lib.elem (builtins.readFile ./public-keys/service-nix-serve-nix-sign.pub) config.nix.settings.trusted-public-keys
    );
    expected = {
      gw = true;
      web = true;
    };
  };

  test_boot = {
    expr = onHosts (config: {
      grub = config.boot.loader.grub.enable;
      systemd-boot = config.boot.loader.systemd-boot.enable;
    });
    expected = {
      gw = {
        grub = true;
        systemd-boot = false;
      };
      web = {
        grub = false;
        systemd-boot = true;
      };
    };
  };
}
