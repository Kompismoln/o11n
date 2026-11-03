{
  lib,
  outputs,
  evalNixosModule,
}:
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

  # Policy: each side of wg0 holds the other's public key, as o11n wrote it.
  test_wg0_peers = {
    expr = onHosts (config: (wg0 config).wireguardPeers);
    expected = {
      gw = [
        {
          PublicKey = builtins.readFile ./public-keys/host-web-wg0-key.pub;
          AllowedIPs = [
            "fd12:3456:7890:0000::0002/128"
            "10.0.0.2/32"
            "fd12:3456:7890:0000:ffff:0002:2011:000b/128"
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

  # Policy: only the gateway listens, forwards and answers DNS for the vpn.
  test_wg0_gateway = {
    expr = onHosts (config: {
      listenPort = (wg0 config).wireguardConfig.ListenPort or null;
      portOpen = lib.elem 51820 config.networking.firewall.allowedUDPPorts;
      forwarding = config.boot.kernel.sysctl."net.ipv4.ip_forward" or 0;
      dns = config.services.kresd.enable;
    });
    expected = {
      gw = {
        listenPort = 51820;
        portOpen = true;
        forwarding = 1;
        dns = true;
      };
      web = {
        listenPort = null;
        portOpen = false;
        forwarding = 0;
        dns = false;
      };
    };
  };

  # Policy: each host, and each service that serves on wg0 on each host it's on, by its name.
  test_wg0_dns_hints = {
    expr = lib.filter (line: builtins.match "hints\\[.*" line != null) (
      lib.splitString "\n" gw.config.services.kresd.extraConfig
    );
    expected = [
      "hints['gw.sample'] = 'fd12:3456:7890:0000::0001'"
      "hints['gw.sample'] = '10.0.0.1'"
      "hints['web.sample'] = 'fd12:3456:7890:0000::0002'"
      "hints['web.sample'] = '10.0.0.2'"
      "hints['archive-web.sample'] = 'fd12:3456:7890:0000:ffff:0002:2011:000b'"
    ];
  };

  test_wg0_fqdn = {
    expr = lib.mapAttrs (_: host: host.network.wg0.fqdn) outputs.org.host;
    expected = {
      gw = "gw.sample";
      web = "web.sample";
    };
  };

  # Policy: the host's users and its roles' services, with uids from their class and id.
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
        web = uids // {
          archive = 2011;
          archives = 4000;
        };
      };
  };

  # Policy: every secret a host needs, and the file in enc/ it is read from.
  test_secrets = {
    expr = onHosts (config: lib.mapAttrs (_: secret: baseNameOf secret.sopsFile) config.sops.secrets);
    expected = {
      gw = {
        "admin/archive-passwd" = "user-admin.yaml";
        "admin/mail" = "user-admin.yaml";
        "admin/passwd-sha512" = "user-admin.yaml";
        "admin/restic-key" = "user-admin.yaml";
        "nix-remote/secret-key" = "service-nix-remote.yaml";
        "nix-remote/ssh-key" = "service-nix-remote.yaml";
        "nix-serve/nix-sign" = "service-nix-serve.yaml";
        "wg0-key" = "host-gw.yaml";
      };
      web = {
        "admin/archive-passwd" = "user-admin.yaml";
        "admin/mail" = "user-admin.yaml";
        "admin/passwd-sha512" = "user-admin.yaml";
        "admin/restic-key" = "user-admin.yaml";
        "domain-sample/tls-cert" = "service-domain-sample.yaml";
        "wg0-key" = "host-web.yaml";
      };
    };
  };

  # Policy: only gw is in rescue mode.
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

  # Policy: gw is the mailserver host, so only web relays mail through msmtp.
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

  # Policy: nix-build reaches the host's own daemon, and on gw, the build host, also build-system;
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

  # Policy: only gw has the remote-builder role: an untrusted relay to its nix-daemon, reached
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
        evalLocation =
          config.services.nginx.virtualHosts."gw.example.com".locations."/nix-eval/".proxyPass or null;
        evaluator = config.systemd.sockets.nix-remote-eval.listenStreams or null;
        evaluatorUser = config.systemd.services."nix-remote-eval@".serviceConfig.User or null;
        orgFlake = config.systemd.services."nix-remote-eval@".environment.ORG_FLAKE or null;
        sshKey = lib.hasInfix (config.sops.secrets."nix-remote/ssh-key".path or "/nonexistent") (
          config.systemd.services."nix-remote-eval@".environment.GIT_SSH_COMMAND or ""
        );
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
        evalLocation = "http://[fd12:3456:7890:ffff::2010:000a]:7338";
        evaluator = [ "[fd12:3456:7890:ffff::2010:000a]:7338" ];
        evaluatorUser = "nix-remote";
        orgFlake = "github:example/sample/{rev}";
        sshKey = true;
        bearer = true;
      };
      web = {
        relay = null;
        relayRestartsWith = null;
        relayUser = null;
        trusted = false;
        tunnel = null;
        location = null;
        evalLocation = null;
        evaluator = null;
        evaluatorUser = null;
        orgFlake = null;
        sshKey = false;
        bearer = false;
      };
    };
  };

  # Policy: without [repository], gw evaluates nothing, and one it can't fetch at a revision fails evaluation.
  test_remote_builder_repository = {
    expr =
      let
        withRepository =
          repository:
          (gw.extendModules {
            specialArgs.org = outputs.org // {
              inherit repository;
            };
          }).config;
        without = withRepository { };
      in
      {
        evaluator = without.systemd.sockets ? nix-remote-eval;
        location = without.services.nginx.virtualHosts."gw.example.com".locations ? "/nix-eval/";
        failed = map (assertion: assertion.message) (
          lib.filter (assertion: !assertion.assertion)
            (withRepository {
              type = "path";
              path = "/srv/org";
            }).assertions
        );
      };
    expected = {
      evaluator = false;
      location = false;
      failed = [
        ''The remote-builder role evaluates the org from [repository] in org.toml, whose type has to be "github" or "git".''
      ];
    };
  };

  # Policy: web relays the daemon and evaluations to gw over wg0, with gw's endpoint as Host and as the
  # name its certificate is checked against.
  test_remote_builder_relay = {
    expr = onHosts (
      config:
      let
        locations = config.services.nginx.virtualHosts."web.example.com".locations or { };
        location = locations."/nix-daemon/" or null;
      in
      lib.mapNullable (location: {
        inherit (location) proxyPass;
        upstream = lib.attrNames config.services.nginx.upstreams.nix-remote-builder.servers;
        host = lib.hasInfix "proxy_set_header Host gw.example.com;" location.extraConfig;
        verify = lib.hasInfix "proxy_ssl_name gw.example.com;" location.extraConfig;
        unbuffered = lib.hasInfix "proxy_buffering off;" location.extraConfig;
        evaluations = locations."/nix-eval/" == location;
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
        evaluations = true;
      };
    };
  };

  # Policy: nothing answers on the reverse tunnel's port, and its account is locked, until it's opened.
  test_reverse_tunnel = {
    expr = onHosts (config: {
      inherit (config.users.users.reverse-tunnel) hashedPassword hashedPasswordFile;
      inherit (config.services.openssh.settings) DenyUsers;
      startedBy =
        config.systemd.services.reverse-tunnel.wantedBy
        ++ config.systemd.timers.reverse-tunnel-expire.wantedBy;
      port = lib.elem 2602 config.networking.firewall.allowedTCPPorts;
    });
    expected =
      let
        closed = {
          hashedPassword = "!";
          hashedPasswordFile = null;
          DenyUsers = [ "reverse-tunnel" ];
          startedBy = [ ];
          port = true;
        };
      in
      {
        gw = closed;
        web = closed;
      };
  };

  # Policy: each stateful principal of a host's has state-snapshot@<id>, of its home where the host keeps it.
  test_snapshots = {
    expr = onHosts (config: {
      snapshots = config.o11n.snapshots;
      template = config.systemd.services ? "state-snapshot@";
    });
    expected = {
      gw = {
        snapshots.user-admin = "/home/admin";
        template = true;
      };
      web = {
        snapshots = {
          user-admin = "/home/admin";
          store-archives = "/var/lib/archives";
        };
        template = true;
      };
    };
  };

  # Policy: admin archives to web from each host it's on, on its schedule, with the secrets of its own sops file.
  test_state_archive = {
    expr = onHosts (config: {
      timer = config.systemd.timers."state-archive@user-admin:web".timerConfig.OnCalendar;
      inherit (config.systemd.services."state-archive@user-admin:web".environment)
        RESTIC_REPOSITORY
        STATE_HOME
        ;
      secrets = lib.mapAttrs (_: secret: baseNameOf secret.sopsFile) (
        lib.filterAttrs (
          name: _: lib.hasSuffix "archive-passwd" name || lib.hasSuffix "restic-key" name
        ) config.sops.secrets
      );
    });
    expected =
      let
        admin = {
          timer = "daily";
          RESTIC_REPOSITORY = "rest:https://archive-web.sample:8000/user-admin/";
          STATE_HOME = "/home/admin";
          secrets = {
            "admin/archive-passwd" = "user-admin.yaml";
            "admin/restic-key" = "user-admin.yaml";
          };
        };
      in
      {
        gw = admin;
        web = admin;
      };
  };

  # Policy: rest-server, as the archive service, keeps each entity's repo in the archives store, at its address on wg0, and lets in
  # each entity with an archive-passwd as its htpasswd entry.
  test_archive =
    let
      inherit (web.config.systemd) services sockets;
      flags = lib.drop 1 (lib.splitString " " services.archive.serviceConfig.ExecStart);
      after = flag: lib.elemAt flags (lib.lists.findFirstIndex (f: f == flag) null flags + 1);
    in
    {
      expr = {
        inherit (services.archive.serviceConfig) User Group;
        path = after "--path";
        htpasswd = builtins.readFile (after "--htpasswd-file");
        inherit (sockets.archive) listenStreams;
        ports = web.config.networking.firewall.interfaces.wg0.allowedTCPPorts;
        onGw = gw.config.systemd.services ? archive;
      };
      expected = {
        User = "archive";
        Group = "archives";
        path = "/var/lib/archives/repos";
        htpasswd = "user-admin:${builtins.readFile ./public-keys/user-admin-archive-passwd.htpasswd}";
        listenStreams = [ "[fd12:3456:7890:0000:ffff:0002:2011:000b]:8000" ];
        ports = [ 8000 ];
        onGw = false;
      };
    };

  # Policy: the stick calls gw on its endpoint, trusts gw's host key and lets in the rescue key.
  test_rescue_usb =
    let
      config = evalNixosModule [
        ../../../nixos/org/rescue-usb.nix
        {
          _module.args.org = outputs.org;
          o11n.rescue-usb.via = "gw";
        }
      ];
      inherit (config.programs.ssh.knownHosts) gw;
    in
    {
      expr = {
        sops = config ? sops;
        inherit (gw) hostNames;
        hostKey = builtins.readFile gw.publicKeyFile == builtins.readFile ./public-keys/host-gw-ssh-key.pub;
        rootKeys =
          map builtins.readFile config.users.users.root.openssh.authorizedKeys.keyFiles == [
            (builtins.readFile ./public-keys/service-rescue-ssh-key.pub)
          ];
        sshd = config.services.openssh.listenAddresses;
        evaluates = builtins.isString config.system.build.toplevel.drvPath;
      };
      expected = {
        sops = false;
        hostNames = [ "[gw.example.com]:2602" ];
        hostKey = true;
        rootKeys = true;
        sshd = [
          {
            addr = "127.0.0.1";
            port = 22;
          }
        ];
        evaluates = true;
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

  test_export_is_plain_data = {
    expr = lib.hasInfix builtins.storeDir (builtins.toJSON outputs.org.export);
    expected = false;
  };

  test_export_entity = {
    expr = {
      inherit (outputs.org.export.entities.service-reverse-tunnel) grants secrets;
      publicKeys = lib.mapAttrs (_: path: builtins.pathExists (./. + "/${path}")) (
        lib.getAttrs [ "age-key" "ssh-key" ] outputs.org.export.entities.service-reverse-tunnel.publicKeys
      );
    };
    expected = {
      grants = [ "host:server" ];
      secrets = {
        sopsFile = "enc/service-reverse-tunnel.yaml";
        identityFile = "enc/service-reverse-tunnel.age";
        decryptionKey = "/keys/service-reverse-tunnel";
      };
      publicKeys = {
        age-key = true;
        ssh-key = true;
      };
    };
  };

  test_export_root = {
    expr = lib.mapAttrs (_: path: builtins.pathExists (./. + "/${path}")) {
      inherit (outputs.org.export.entities.root-1.publicKeys) age-key;
      inherit (outputs.org.export.entities.root-1.secrets) identityFile;
    };
    expected = {
      age-key = true;
      identityFile = true;
    };
  };

  test_export_classes = {
    expr = outputs.org.export.classes == import ../../../org/classes.nix;
    expected = true;
  };
}
