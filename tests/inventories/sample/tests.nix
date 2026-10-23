# tests/inventories/sample/tests.nix
{ lib, outputs }:
let
  inherit (outputs.nixosConfigurations) gw web;

  onHosts = f: {
    gw = f gw.config;
    web = f web.config;
  };

  wg0 = config: config.systemd.network.netdevs."20-wg0";

  withoutStoreHashes =
    text:
    lib.concatStrings (
      lib.filter lib.isString (builtins.split "${builtins.storeDir}/[0-9a-z]{32}-" text)
    );

  forceCommand =
    config: user:
    let
      lines = map lib.trim (lib.splitString "\n" config.services.openssh.extraConfig);
    in
    withoutStoreHashes (
      lib.removePrefix "ForceCommand " (
        lib.elemAt lines (lib.lists.findFirstIndex (line: line == "Match User ${user}") null lines + 1)
      )
    );
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

  test_wg0_fqdn = {
    expr = lib.mapAttrs (_: host: host.network.wg0.fqdn) outputs.org.host;
    expected = {
      gw = "gw.sample";
      web = "web.sample";
    };
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
        gw = uids // {
          nix-remote = 2010;
        };
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
        "nix-remote/secret-key" = "service-nix-remote.yaml";
        "nix-serve/nix-sign" = "service-nix-serve.yaml";
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

  # nix-build reaches the host's own daemon, and on gw, the build host, also build-system;
  # nix-switch runs switch-system as root. Hosts substitute from gw, the substituter.
  test_deploy = {
    expr = onHosts (config: {
      nix-build = lib.replaceStrings [ (withoutStoreHashes "${config.nix.package}") ] [ "nix.package" ] (
        forceCommand config "nix-build"
      );
      nix-switch = forceCommand config "nix-switch";
      sudo = map (rule: map (command: withoutStoreHashes command.command) rule.commands) (
        lib.filter (rule: rule.users == [ "nix-switch" ]) config.security.sudo.extraRules
      );
      substituters = lib.filter (lib.hasPrefix "http://") config.nix.settings.substituters;
    });
    expected =
      let
        common = {
          nix-switch = "sudo switch-system/bin/switch-system \\$SSH_ORIGINAL_COMMAND";
          sudo = [
            [
              "switch-system/bin/switch-system"
              "switch-system/bin/switch-system *"
            ]
          ];
        };
      in
      {
        gw = common // {
          nix-build = "nix-build-command";
          substituters = [ ];
        };
        web = common // {
          nix-build = "nix.package/bin/nix-daemon --stdio";
          substituters = [ "http://gw.sample:5000?priority=50" ];
        };
      };
  };

  test_build_host_without_substituter = {
    expr =
      let
        inherit
          (web.extendModules {
            specialArgs.org = outputs.org // {
              build-hosts = [ "web" ];
            };
          })
          config
          ;
      in
      map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) config.assertions);
    expected = [
      "Build host web needs the substituter role, or no host can fetch what it builds."
    ];
  };

  test_reach = {
    expr = lib.mapAttrs (_: host: lib.mapAttrs (_: network: network.fqdn) host.reach) outputs.org.host;
    expected = {
      gw = {
        gw = "gw.sample";
        web = "web.sample";
      };
      web = {
        gw = "gw.sample";
        web = "web.sample";
      };
    };
  };

  # Only gw has the remote-builder role: an untrusted relay to its nix-daemon, reached
  # through the tunnel, behind its nginx and the bearer from nix-remote's secret-key.
  test_remote_builder = {
    expr = onHosts (
      config:
      let
        template = config.sops.templates."nix-remote/nginx-bearer" or null;
      in
      {
        relay = config.systemd.sockets.nix-remote.listenStreams or null;
        relayRestartsWith = config.systemd.sockets.nix-remote.partOf or null;
        relayUser = config.systemd.services."nix-remote@".serviceConfig.User or null;
        trusted = lib.elem "nix-remote" config.nix.settings.trusted-users;
        tunnel = lib.mapNullable (service: lib.last (lib.splitString " " service.serviceConfig.ExecStart)) (
          config.systemd.services.nix-remote-tunnel or null
        );
        location =
          config.services.nginx.virtualHosts."gw.example.com".locations."/nix-daemon/".proxyPass or null;
        bearer =
          template != null
          && lib.hasInfix config.sops.placeholder."nix-remote/secret-key" template.content
          && lib.hasInfix template.path config.services.nginx.appendHttpConfig;
      }
    );
    expected = {
      gw = {
        relay = [ "[fd12:3456:7890:ffff::2010:000a]:7337" ];
        relayRestartsWith = [ "nix-remote-tunnel.service" ];
        relayUser = "nix-remote";
        trusted = false;
        tunnel = "'relay+pht://[fd12:3456:7890:ffff::2010:000a]:8080/[fd12:3456:7890:ffff::2010:000a]:7337?authorizePath=/nix-daemon/authorize&pushPath=/nix-daemon/push&pullPath=/nix-daemon/pull'";
        location = "http://[fd12:3456:7890:ffff::2010:000a]:8080";
        bearer = true;
      };
      web = {
        relay = null;
        relayRestartsWith = null;
        relayUser = null;
        trusted = false;
        tunnel = null;
        location = null;
        bearer = false;
      };
    };
  };

  # web relays to gw over wg0, with gw's endpoint as Host and as the name its certificate
  # is checked against.
  test_remote_builder_relay = {
    expr = onHosts (
      config:
      let
        location = config.services.nginx.virtualHosts."web.example.com".locations."/nix-daemon/" or null;
      in
      lib.mapNullable (location: {
        inherit (location) proxyPass;
        upstream = lib.attrNames config.services.nginx.upstreams.nix-remote-builder.servers;
        host = lib.hasInfix "proxy_set_header Host gw.example.com;" location.extraConfig;
        verify = lib.hasInfix "proxy_ssl_name gw.example.com;" location.extraConfig;
        unbuffered = lib.hasInfix "proxy_buffering off;" location.extraConfig;
      }) location
    );
    expected = {
      gw = null;
      web = {
        proxyPass = "https://nix-remote-builder";
        upstream = [ "[fd12:3456:7890:0000::0001]:443" ];
        host = true;
        verify = true;
        unbuffered = true;
      };
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
