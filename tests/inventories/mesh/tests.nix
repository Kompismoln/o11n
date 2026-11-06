{
  pkgs,
  lib,
  outputs,
}:
let
  inherit (outputs) org;
  inherit (outputs.nixosConfigurations) alpha beta gamma;

  key = host: vpn: builtins.readFile ./public-keys/host-${host}-${vpn}-key.pub;

  peers = host: vpn: host.config.systemd.network.netdevs."20-${vpn}".wireguardPeers;

  # Accommodating for the org, which is evaluated once: the module alone is evaluated against an altered copy of it.
  failing =
    alter: name:
    let
      altered = alter org;
      inherit
        (import "${pkgs.path}/nixos/lib/eval-config.nix" {
          inherit pkgs lib;
          inherit (pkgs.stdenv.hostPlatform) system;
          specialArgs = {
            org = altered;
            host = altered.host.${name};
          };
          modules = [
            ../../../nixos/org/wireguard.nix
            {
              options.sops.secrets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
              config.system.stateVersion = lib.trivial.release;
            }
          ];
        })
        config
        ;
    in
    map (assertion: assertion.message) (
      lib.filter (
        assertion: !assertion.assertion && lib.hasPrefix "vpn." assertion.message
      ) config.assertions
    );

  updateHost =
    name: change: org:
    org
    // {
      host = org.host // {
        ${name} = org.host.${name} // change;
      };
    };
  updateVpn =
    name: change: org:
    org
    // {
      vpn = org.vpn // {
        ${name} = org.vpn.${name} // change;
      };
    };
in
{
  # Policy: on the mesh each host peers with each, at its own addresses, dialing those with an endpoint, and keeping
  # the connection open where it has none itself.
  test_mesh_peers = {
    expr = {
      alpha = peers alpha "wg1";
      gamma = peers gamma "wg1";
    };
    expected = {
      alpha = [
        {
          PublicKey = key "beta" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0002/128"
            "10.0.1.2/32"
          ];
          Endpoint = "beta.example.com:51821";
        }
        {
          PublicKey = key "gamma" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0003/128"
            "10.0.1.3/32"
          ];
        }
      ];
      gamma = [
        {
          PublicKey = key "alpha" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0001/128"
            "10.0.1.1/32"
          ];
          Endpoint = "alpha.example.com:51821";
          PersistentKeepalive = 25;
        }
        {
          PublicKey = key "beta" "wg1";
          AllowedIPs = [
            "fd12:3456:7890:0001::0002/128"
            "10.0.1.2/32"
          ];
          Endpoint = "beta.example.com:51821";
          PersistentKeepalive = 25;
        }
      ];
    };
  };

  test_hub_peers = {
    expr = map (peer: peer.PublicKey) (peers gamma "wg0");
    expected = [ (key "alpha" "wg0") ];
  };

  # Policy: on the mesh a host listens where it can be dialed, and forwards nothing.
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
        port = 51821;
        firewall = [
          51820
          51821
        ];
        forwards = 1;
      }
      {
        port = 51821;
        firewall = [ 51821 ];
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
    expr = map (name: failing (org: org) name) [
      "alpha"
      "beta"
      "gamma"
    ];
    expected = [
      [ ]
      [ ]
      [ ]
    ];
  };

  test_unreachable_pair = {
    expr = map (failing (updateHost "beta" { endpoint = null; })) [
      "alpha"
      "gamma"
    ];
    expected = [
      [ ]
      [
        "vpn.wg1 is a mesh, where one of each pair of hosts dials the other at its endpoint: gamma and beta have none, so give one of each pair an endpoint, or take one of them off wg1."
      ]
    ];
  };

  test_mesh_without_gateway = {
    expr = failing (updateVpn "wg1" { gateway = "alpha"; }) "beta";
    expected = [
      "vpn.wg1 is a mesh, which has no gateway to forward or proxy through: remove its gateway and proxy, or set topology = \"hub\"."
    ];
  };

  test_hub_with_gateway = {
    expr = failing (updateVpn "wg0" { gateway = null; }) "beta";
    expected = [
      "vpn.wg0 is a hub, whose hosts peer through its gateway: set its gateway to a host on it."
    ];
  };
}
