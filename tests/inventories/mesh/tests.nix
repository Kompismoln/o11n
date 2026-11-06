{
  lib,
  o11nLib,
  outputs,
}:
let
  inherit (outputs.nixosConfigurations)
    alpha
    beta
    gamma
    delta
    ;

  key = host: vpn: builtins.readFile ./public-keys/host-${host}-${vpn}-key.pub;

  peers = host: vpn: host.config.systemd.network.netdevs."20-${vpn}".wireguardPeers;

  # Accommodating for the inventory, which has to evaluate: what would fail is evaluated from an altered copy of its spec.
  alter =
    change:
    o11nLib.evalContext {
      path = ./.;
      flake = {
        outPath = ./.;
        inputs = { };
      };
      spec = lib.recursiveUpdate outputs.context.spec change;
    };

  failing =
    change: name:
    let
      inherit ((o11nLib.mkNixosConfigurations (alter change)).${name}) config;
    in
    map (assertion: assertion.message) (
      lib.filter (
        assertion:
        !assertion.assertion
        && (
          lib.hasPrefix "vpn." assertion.message
          || lib.hasInfix "a mesh" assertion.message
          || lib.hasInfix "suffix" assertion.message
          || lib.hasInfix "listens on" assertion.message
        )
      ) config.assertions
    );

  replicates =
    change: allotment:
    (builtins.tryEval (builtins.deepSeq (alter change).org.allotment.${allotment}.replicas true))
    .success;

  carol = hosts: {
    user.carol = {
      id = 0;
      principal.hasPasswd = false;
      principal.hasPublicKey = false;
    };
    host = lib.genAttrs hosts (_: {
      users = [ "carol" ];
    });
  };

  archive = lib.recursiveUpdate (carol [ "delta" ]) {
    user.carol.principal.state.archives = [ "gamma" ];
    host.gamma.roles = [ "archive" ];
    role.archive = {
      services = [ "archive" ];
      stores = [ "archives" ];
    };
    service.archive = {
      id = 11;
      vpn = "wg1";
      principal.hasPublicKey = false;
    };
    store.archives = {
      id = 0;
      principal.hasPublicKey = false;
      principal.hasSFTP = false;
    };
  };
in
{
  # Policy: on the mesh each host peers with each, at its own addresses, dialing those with an endpoint, and keeping
  # the connection open where it has none itself; two without one don't peer.
  test_mesh_peers = {
    expr = {
      alpha = map (peer: peer.PublicKey) (peers alpha "wg1");
      gamma = peers gamma "wg1";
      delta = map (peer: peer.PublicKey) (peers delta "wg1");
    };
    expected = {
      alpha = [
        (key "beta" "wg1")
        (key "delta" "wg1")
        (key "gamma" "wg1")
      ];
      gamma = [
        {
          PublicKey = key "alpha" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0001/128"
            "10.0.1.1/32"
          ];
          Endpoint = "alpha.example.com:52101";
          PersistentKeepalive = 25;
        }
        {
          PublicKey = key "beta" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0002/128"
            "10.0.1.2/32"
          ];
          Endpoint = "beta.example.com:52102";
          PersistentKeepalive = 25;
        }
      ];
      delta = [
        (key "alpha" "wg1")
        (key "beta" "wg1")
      ];
    };
  };

  test_reaches = {
    expr = lib.mapAttrs (_: vpn: vpn.reaches) outputs.org.vpn;
    expected = {
      wg0 = {
        alpha = [
          "beta"
          "gamma"
        ];
        beta = [
          "alpha"
          "gamma"
        ];
        gamma = [
          "alpha"
          "beta"
        ];
      };
      wg1 = {
        alpha = [
          "beta"
          "delta"
          "gamma"
        ];
        beta = [
          "alpha"
          "delta"
          "gamma"
        ];
        delta = [
          "alpha"
          "beta"
        ];
        gamma = [
          "alpha"
          "beta"
        ];
      };
    };
  };

  test_hub_peers = {
    expr = map (peer: peer.PublicKey) (peers gamma "wg0");
    expected = [ (key "alpha" "wg0") ];
  };

  # Policy: on the mesh a host listens where it can be dialed, on a port of its own, and forwards nothing.
  test_mesh_listens = {
    expr =
      map
        (host: {
          port = host.config.systemd.network.netdevs."20-wg1".wireguardConfig.ListenPort or null;
          firewall = host.config.networking.firewall.allowedUDPPorts;
          forwards = host.config.boot.kernel.sysctl."net.ipv4.ip_forward" or 0;
        })
        [
          alpha
          beta
          gamma
        ];
    expected = [
      {
        port = 52101;
        firewall = [
          51820
          52101
        ];
        forwards = 1;
      }
      {
        port = 52102;
        firewall = [ 52102 ];
        forwards = 0;
      }
      {
        port = null;
        firewall = [ ];
        forwards = 0;
      }
    ];
  };

  test_mesh_routes = {
    expr = map (route: route.Destination) gamma.config.systemd.network.networks."30-wg1".routes;
    expected = [
      "fd12:3456:7890:0001::/64"
      "10.0.1.0/24"
    ];
  };

  test_passes = {
    expr = map (name: failing { } name) [
      "alpha"
      "beta"
      "gamma"
      "delta"
    ];
    expected = [
      [ ]
      [ ]
      [ ]
      [ ]
    ];
  };

  # Policy: a replica syncs with the allotment's host over the first vpn they share, which it has to reach it on.
  test_allotment_reach = {
    expr = {
      dialed = replicates (lib.recursiveUpdate (carol [
        "alpha"
        "gamma"
      ]) { allotment."user-carol@gamma".replicas = [ "alpha" ]; }) "user-carol@gamma";
      unreachable = replicates (lib.recursiveUpdate (carol [
        "gamma"
        "delta"
      ]) { allotment."user-carol@gamma".replicas = [ "delta" ]; }) "user-carol@gamma";
    };
    expected = {
      dialed = true;
      unreachable = false;
    };
  };

  test_archive_reach = {
    expr = {
      unreachable = failing archive "delta";
      dialed = failing (lib.recursiveUpdate archive {
        host.gamma.endpoint = "gamma.example.com";
      }) "delta";
    };
    expected = {
      unreachable = [
        "user-carol archives to gamma on wg1, a mesh on which neither delta nor gamma has an endpoint to be dialed at: give one of them an endpoint, or fix principal.state.archives."
      ];
      dialed = [ ];
    };
  };

  test_mesh_without_gateway = {
    expr = failing { vpn.wg1.gateway = "alpha"; } "beta";
    expected = [
      "vpn.wg1 is a mesh, which has no gateway to forward or proxy through: remove its gateway and proxy, or set topology = \"hub\"."
    ];
  };

  # Policy: a network with a suffix takes its ipv6 address from the router's prefix and the suffix, and asks the router
  # for none; one without asks as before.
  test_suffix = {
    expr = lib.mapAttrs (_: network: {
      inherit (network.networkConfig) DHCP;
      ra = network.ipv6AcceptRAConfig or { };
    }) (lib.filterAttrs (name: _: lib.hasPrefix "10-" name) gamma.config.systemd.network.networks);
    expected = {
      "10-eth0" = {
        DHCP = "ipv4";
        ra = {
          Token = "static:::fba";
          DHCPv6Client = "no";
        };
      };
      "10-wlan0" = {
        DHCP = "yes";
        ra = { };
      };
    };
  };

  test_suffix_unique = {
    expr = {
      host = failing { host.gamma.network.wifi.suffix = "::fba"; } "gamma";
      org = failing {
        host.delta.network.eth = {
          interface = "eth0";
          mode = "dhcp";
          suffix = "::fba";
        };
      } "delta";
      static = failing { host.gamma.network.eth.mode = "static"; } "gamma";
    };
    expected = {
      host = [
        "gamma's network eth has the suffix ::fba, as another network does, which could share its link and prefix: give each its own."
        "gamma's network wifi has the suffix ::fba, as another network does, which could share its link and prefix: give each its own."
      ];
      org = [
        "delta's network eth has the suffix ::fba, as another network does, which could share its link and prefix: give each its own."
      ];
      static = [
        "gamma's network eth has a suffix, which only a dhcp network takes: remove it, or set mode = \"dhcp\"."
      ];
    };
  };

  test_ports = {
    expr = lib.mapAttrs (_: member: member.port) outputs.org.vpn.wg1.members // {
      hub = lib.mapAttrs (_: member: member.port) outputs.org.vpn.wg0.members;
    };
    expected = {
      alpha = 52101;
      beta = 52102;
      gamma = 52103;
      delta = 52104;
      hub = {
        alpha = 51820;
        beta = null;
        gamma = null;
      };
    };
  };

  test_ports_apart = {
    expr = failing { vpn.wg0.port = 52101; } "alpha";
    expected = [
      "alpha listens on 52101 for more than one of its vpns: set the port of one of them apart."
    ];
  };

  # Policy: what a host behind the router listens on for its vpns is forwarded to it on IPv4 and let in on IPv6 by its
  # suffix, ahead of the dmz.
  test_router_firewall = {
    expr =
      let
        file = outputs.org.host.windsor.openwrt.files."/etc/config/firewall";
      in
      lib.filter (line: lib.hasPrefix "config " line || lib.hasInfix "dest_" line) (
        lib.splitString "\n" file
      );
    expected = [
      "config redirect 'o11n_alpha_wg0'"
      "\toption dest_ip '192.168.1.11'"
      "\toption dest_port '51820'"
      "config rule 'o11n_alpha_wg0_6'"
      "\toption dest_ip '::a/::ffff:ffff:ffff:ffff'"
      "\toption dest_port '51820'"
      "config redirect 'o11n_alpha_wg1'"
      "\toption dest_ip '192.168.1.11'"
      "\toption dest_port '52101'"
      "config rule 'o11n_alpha_wg1_6'"
      "\toption dest_ip '::a/::ffff:ffff:ffff:ffff'"
      "\toption dest_port '52101'"
      "config redirect 'o11n_beta_wg1'"
      "\toption dest_ip '192.168.1.12'"
      "\toption dest_port '52102'"
      "config rule 'o11n_beta_wg1_6'"
      "\toption dest_ip '::b/::ffff:ffff:ffff:ffff'"
      "\toption dest_port '52102'"
      "config redirect 'o11n_dmz'"
      "\toption dest_ip '192.168.1.12'"
    ];
  };

  test_router_files = {
    expr = {
      paths = lib.attrNames outputs.org.host.windsor.openwrt.files;
      inherit (outputs.org.host.windsor.openwrt.files)
        "/etc/config/dhcp"
        "/etc/config/system"
        "/etc/config/wireless"
        ;
      nixos = outputs.nixosConfigurations ? windsor;
    };
    expected = {
      paths = [
        "/etc/config/dhcp"
        "/etc/config/dropbear"
        "/etc/config/firewall"
        "/etc/config/network"
        "/etc/config/system"
        "/etc/config/wireless"
        "/etc/dropbear/authorized_keys"
      ];
      "/etc/config/dhcp" = ''
        config host 'o11n_alpha'
        ''\toption ip '192.168.1.11'
        ''\toption mac '02:00:00:00:00:01'
        ''\toption name 'alpha'

        config host 'o11n_beta'
        ''\toption ip '192.168.1.12'
        ''\toption name 'beta'
      '';
      "/etc/config/system" = ''
        config system 'system'
        ''\toption hostname 'windsor'
        ''\toption zonename 'UTC'
      '';
      "/etc/config/wireless" = ''
        config wifi-iface 'default_radio0'
        ''\toption device 'radio0'
        ''\toption encryption 'psk2'
        ''\toption key '@o11n-secret:wifi-key@'
        ''\toption mode 'ap'
        ''\toption network 'lan'
        ''\toption ssid 'windsor'
      '';
      nixos = false;
    };
  };

  test_router_refuses = {
    expr =
      let
        throws =
          change: path:
          !(builtins.tryEval (builtins.deepSeq (lib.attrByPath path null (alter change).org) true)).success;
      in
      {
        notRouter = throws { host.gamma.behind = "alpha"; } [
          "host"
          "gamma"
          "behind"
        ];
        noLan = throws { host.gamma.behind = "windsor"; } [
          "host"
          "windsor"
          "openwrt"
          "files"
        ];
        ownName =
          throws
            {
              host.windsor.openwrt.uci.firewall.o11n_mine = {
                _type = "rule";
              };
            }
            [
              "host"
              "windsor"
              "openwrt"
              "files"
            ];
        foreignSecret =
          throws
            {
              host.windsor.openwrt.uci.wireless.default_radio0.key.secret = "nothing";
            }
            [
              "host"
              "windsor"
              "openwrt"
              "files"
            ];
        passes = throws { } [
          "host"
          "windsor"
          "openwrt"
          "files"
        ];
      };
    expected = {
      notRouter = true;
      noLan = true;
      ownName = true;
      foreignSecret = true;
      passes = false;
    };
  };

  test_hub_with_gateway = {
    expr = failing { vpn.wg0.gateway = null; } "beta";
    expected = [
      "vpn.wg0 is a hub, whose hosts peer through its gateway: set its gateway to a host on it."
    ];
  };
}
