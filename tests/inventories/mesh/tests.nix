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

  # Policy: an allotment's vpn, where it has one, is what it syncs over, which its host and replicas have to be on.
  test_allotment_vpn = {
    expr =
      let
        allotment =
          change:
          (alter (
            lib.recursiveUpdate (carol [
              "alpha"
              "gamma"
              "delta"
            ]) { allotment."user-carol@gamma" = change; }
          )).org.allotment."user-carol@gamma";
        interface = change: (allotment change).networks.alpha.interface;
        syncs = change: (builtins.tryEval (builtins.deepSeq (allotment change).replicas true)).success;
      in
      {
        first = interface { replicas = [ "alpha" ]; };
        mesh = interface {
          replicas = [ "alpha" ];
          vpn = "wg1";
        };
        notOn = syncs {
          replicas = [ "delta" ];
          vpn = "wg0";
        };
      };
    expected = {
      first = "wg0";
      mesh = "wg1";
      notOn = false;
    };
  };

  # Policy: on a vpn without name servers a host names in /etc/hosts itself and those it reaches, and on one with
  # them, none.
  test_mesh_hosts = {
    expr =
      let
        names = lib.concatLists (lib.attrValues gamma.config.networking.hosts);
      in
      {
        inherit (gamma.config.networking.hosts) "fd12:3456:7890:0001::0001";
        own = lib.elem "gamma.data" names;
        unreached = lib.elem "delta.data" names;
        hub = lib.any (lib.hasSuffix ".access") names;
      };
    expected = {
      "fd12:3456:7890:0001::0001" = [ "alpha.data" ];
      own = true;
      unreached = false;
      hub = false;
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

  # Policy: what a host behind the router listens on for its vpns is forwarded to it, on the network it reaches it on.
  test_router_forwards = {
    expr = {
      inherit (outputs.org.host.windsor.router) forwards;
      lan = lib.mapAttrs (_: network: network.address4) outputs.org.host.windsor.router.lan;
    };
    expected = {
      forwards = [
        {
          host = "alpha";
          vpn = "wg0";
          port = 51820;
        }
        {
          host = "alpha";
          vpn = "wg1";
          port = 52101;
        }
        {
          host = "beta";
          vpn = "wg1";
          port = 52102;
        }
      ];
      lan = {
        alpha = "192.168.1.11";
        beta = "192.168.1.12";
      };
    };
  };

  # Policy: OpenWrt forwards on IPv4 and lets in on IPv6 by the suffix, ahead of the dmz.
  test_router_firewall = {
    expr = lib.filter (
      line: lib.hasInfix "=redirect" line || lib.hasInfix "=rule" line || lib.hasInfix "dest_ip" line
    ) (lib.splitString "\n" outputs.org.host.windsor.openwrt.changes.firewall);
    expected = [
      "uci set 'firewall.o11n_alpha_wg0=redirect'"
      "uci set 'firewall.o11n_alpha_wg0.dest_ip=192.168.1.11'"
      "uci set 'firewall.o11n_alpha_wg0_6=rule'"
      "uci set 'firewall.o11n_alpha_wg0_6.dest_ip=::a/::ffff:ffff:ffff:ffff'"
      "uci set 'firewall.o11n_alpha_wg1=redirect'"
      "uci set 'firewall.o11n_alpha_wg1.dest_ip=192.168.1.11'"
      "uci set 'firewall.o11n_alpha_wg1_6=rule'"
      "uci set 'firewall.o11n_alpha_wg1_6.dest_ip=::a/::ffff:ffff:ffff:ffff'"
      "uci set 'firewall.o11n_beta_wg1=redirect'"
      "uci set 'firewall.o11n_beta_wg1.dest_ip=192.168.1.12'"
      "uci set 'firewall.o11n_beta_wg1_6=rule'"
      "uci set 'firewall.o11n_beta_wg1_6.dest_ip=::b/::ffff:ffff:ffff:ffff'"
      "uci set 'firewall.o11n_dmz=redirect'"
      "uci set 'firewall.o11n_dmz.dest_ip=192.168.1.12'"
    ];
  };

  test_router_changes = {
    expr = {
      paths = lib.attrNames outputs.org.host.windsor.openwrt.files;
      inherit (outputs.org.host.windsor.openwrt.changes)
        dhcp
        network
        system
        wireless
        ;
      nixos = outputs.nixosConfigurations ? windsor;
    };
    expected = {
      paths = [
        "/etc/crontabs/root"
        "/etc/dropbear/authorized_keys"
        "/etc/hotplug.d/iface/90-o11n-glesys"
        "/etc/o11n/glesys"
        "/etc/o11n/uci"
      ];
      dhcp = ''
        for section in $(uci -q show dhcp | sed -n 's/^dhcp\.\(o11n_[A-Za-z0-9_]*\)=.*/\1/p'); do
        ''\tuci delete "dhcp.$section"
        done
        uci set 'dhcp.o11n_alpha=host'
        uci set 'dhcp.o11n_alpha.ip=192.168.1.11'
        uci set 'dhcp.o11n_alpha.mac=02:00:00:00:00:01'
        uci set 'dhcp.o11n_alpha.name=alpha'
        uci set 'dhcp.o11n_beta=host'
        uci set 'dhcp.o11n_beta.ip=192.168.1.12'
        uci set 'dhcp.o11n_beta.name=beta'
      '';
      network = ''
        uci set 'network.lan=interface'
        uci -q delete network.lan.ipaddr || :
        uci add_list 'network.lan.ipaddr=192.168.1.1/24'
      '';
      system = ''
        uci set 'system.@system[0].zonename=UTC'
        uci set 'system.@system[0].hostname=windsor'
      '';
      wireless = ''
        uci set 'wireless.default_radio0=wifi-iface'
        uci set 'wireless.default_radio0.encryption=psk2'
        uci set 'wireless.default_radio0.key=@o11n-secret:wifi-key@'
        uci set 'wireless.default_radio0.ssid=windsor'
        uci set 'wireless.radio0=wifi-device'
        uci set 'wireless.radio0.disabled=0'
      '';
      nixos = false;
    };
  };

  # Policy: the router updates the A records of the hosts behind it that have an endpoint, with a key the image leaves
  # out, as it does any file with a secret, and the changes to a UCI file with one.
  test_router_image = {
    expr =
      let
        inherit (outputs.org.host.windsor) openwrt router;
        firstBoot = openwrt.imageFiles."/etc/uci-defaults/99-o11n";
      in
      {
        inherit (router.glesys) records;
        key = lib.hasInfix "key='@o11n-secret:glesys-key@'" openwrt.files."/etc/o11n/glesys";
        image = lib.attrNames openwrt.imageFiles;
        dhcp = lib.hasInfix "dhcp.o11n_alpha=host" firstBoot;
        wireless = lib.hasInfix "wireless." firstBoot;
      };
    expected = {
      records = [
        "alpha.example.com"
        "beta.example.com"
      ];
      key = true;
      image = [
        "/etc/crontabs/root"
        "/etc/dropbear/authorized_keys"
        "/etc/hotplug.d/iface/90-o11n-glesys"
        "/etc/uci-defaults/99-o11n"
      ];
      dhcp = true;
      wireless = false;
    };
  };

  # Policy: what o11n names its sections by, as a host's name, has whatever UCI doesn't take in its place.
  test_router_names = {
    expr =
      let
        inherit
          ((alter {
            host.epsilon-one = {
              id = 6;
              roles = [ ];
              vpns = [ ];
              users = [ ];
              system = "x86_64-linux";
              behind = "windsor";
              network.eth = {
                interface = "eth0";
                mode = "dhcp";
                suffix = "::e";
                address4 = "192.168.1.16";
              };
            };
          }).org.host.windsor.openwrt.changes
          )
          dhcp
          ;
      in
      lib.hasInfix "uci set 'dhcp.o11n_epsilon_one=host'" dhcp;
    expected = true;
  };

  test_router_refuses = {
    expr =
      let
        throws =
          change: path:
          !(builtins.tryEval (builtins.deepSeq (lib.attrByPath path null (alter change).org) true)).success;
        changes = [
          "host"
          "windsor"
          "openwrt"
          "changes"
        ];
      in
      {
        notRouter = throws { host.gamma.behind = "alpha"; } [
          "host"
          "gamma"
          "behind"
        ];
        noOpenwrt = throws { host.alpha.router = { }; } [
          "host"
          "alpha"
          "router"
        ];
        noLan = throws { host.gamma.behind = "windsor"; } changes;
        outsideLan = throws { host.windsor.router.prefixLength4 = 30; } changes;
        dmzAhead = throws { host.windsor.router.dmz = "gamma"; } [
          "host"
          "windsor"
          "router"
          "dmz"
        ];
        ownName = throws { host.windsor.openwrt.uci.firewall.o11n_mine._type = "rule"; } changes;
        foreignSecret = throws {
          host.windsor.openwrt.uci.wireless.default_radio0.key.secret = "nothing";
        } changes;
        untyped = throws { host.windsor.openwrt.uci.network.wan.proto = "dhcp"; } changes;
        typedIndex = throws { host.windsor.openwrt.uci.system."@system[0]"._type = "system"; } changes;
        notSection = throws { host.windsor.openwrt.uci.network."wan.6"._type = "interface"; } changes;
        passes = throws { } changes;
      };
    expected = {
      notRouter = true;
      noOpenwrt = true;
      noLan = true;
      outsideLan = true;
      dmzAhead = true;
      ownName = true;
      foreignSecret = true;
      untyped = true;
      typedIndex = true;
      notSection = true;
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
