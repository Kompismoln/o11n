# nixos/wireguard.nix
{
  config,
  host,
  lib,
  pkgs,
  org,
  ...
}:

let

  vpns = builtins.filter (vpn: vpn.enable) (map (vpnName: org.vpn.${vpnName}) host.vpns);

  peers =
    vpn:
    lib.filter (
      peer: lib.elem vpn.name peer.vpns && (peer.name == vpn.gateway || host.name == vpn.gateway)
    ) (lib.attrValues org.host);

  # Policy: the host first, then its principals by name.
  onHost =
    vpn: peer:
    [ vpn.members.${peer.name} ]
    ++ lib.attrValues (
      lib.filterAttrs (name: member: member.host == peer.name && name != peer.name) vpn.members
    );

  isGateway = lib.any (vpn: host.name == vpn.gateway) vpns;
  dnsFor = lib.filter (vpn: lib.elem host.name vpn.dns) vpns;
  proxyFor = lib.filter (vpn: host.name == vpn.gateway && vpn.proxy) vpns;
in
{

  services.kresd = lib.mkIf (dnsFor != [ ]) {
    enable = true;

    listenPlain = builtins.concatMap (vpn: [
      "[${host.network.${vpn.name}.address}]:53"
      "${host.network.${vpn.name}.address4}:53"
    ]) dnsFor;

    extraConfig = ''
      modules = { 'hints > iterate' }
      ${lib.concatStringsSep "\n" (
        builtins.concatMap (
          vpn:
          map (
            peer:
            lib.concatStrings (
              map (
                member:
                lib.concatMapStrings (address: "hints['${member.fqdn}'] = '${address}'\n") (
                  lib.filter (address: address != null) [
                    member.address
                    member.address4
                  ]
                )
              ) (onHost vpn peer)
            )
          ) (peers vpn)
        ) dnsFor
      )}
    '';
  };

  systemd.services."systemd-networkd".preStop = lib.concatStringsSep "\n" (
    map (vpn: "${pkgs.iproute2}/bin/ip link delete ${vpn.interface}") (
      lib.filter (vpn: vpn.resetOnRebuild) vpns
    )
  );

  networking = {
    wireguard.enable = true;
    networkmanager.unmanaged = map (interface: "interface-name:${interface}") host.vpns;

    nat = lib.mkIf (proxyFor != [ ]) {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = map (vpn: vpn.interface) proxyFor;
      externalInterface = host.network.eth.interface;
    };

    firewall = {
      allowedUDPPorts = map (vpn: vpn.port) (lib.filter (vpn: host.name == vpn.gateway) vpns);
      trustedInterfaces = map (vpn: vpn.interface) (builtins.filter (vpn: vpn.trusted) vpns);
      interfaces = lib.mkMerge [
        (lib.listToAttrs (
          map (
            vpn:
            lib.nameValuePair vpn.interface {
              inherit (vpn) allowedTCPPorts allowedUDPPorts;
            }
          ) (builtins.filter (vpn: !vpn.trusted) vpns)
        ))
        (lib.listToAttrs (
          map (
            vpn:
            lib.nameValuePair vpn.interface {
              allowedTCPPorts = [ 53 ];
              allowedUDPPorts = [ 53 ];
            }
          ) (builtins.filter (vpn: !vpn.trusted) dnsFor)
        ))
      ];
    };
  };

  assertions = lib.concatMap (vpn: [
    {
      assertion = lib.all (other: lib.elem vpn.name org.host.${other}.vpns) ([ vpn.gateway ] ++ vpn.dns);
      message = "vpn.${vpn.name}'s gateway and dns are hosts on it: add ${vpn.name} to the vpns of ${
        lib.concatStringsSep ", " (
          lib.filter (other: !lib.elem vpn.name org.host.${other}.vpns) ([ vpn.gateway ] ++ vpn.dns)
        )
      }.";
    }
  ]) vpns;

  sops.secrets = lib.listToAttrs (
    map (
      vpn:
      lib.nameValuePair vpn.key {
        owner = "systemd-network";
        group = "systemd-network";
      }
    ) vpns
  );

  boot.kernel.sysctl = lib.mkIf isGateway {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  systemd.network = {
    enable = true;

    netdevs = lib.genAttrs' vpns (
      vpn:
      lib.nameValuePair "20-${vpn.interface}" {
        netdevConfig = {
          Kind = "wireguard";
          Name = vpn.interface;
        };
        wireguardConfig = {
          PrivateKeyFile = config.sops.secrets.${vpn.key}.path;
          ListenPort = lib.mkIf (host.name == vpn.gateway) vpn.port;
        };
        wireguardPeers = map (
          peer:
          let
            base = {
              PublicKey = builtins.readFile peer.publicKeys.${vpn.key};
              AllowedIPs =
                if peer.name == vpn.gateway then
                  [
                    vpn.address
                    vpn.address4
                  ]
                  ++ (lib.optionals vpn.proxy [ "::/0" ])
                else
                  lib.concatLists (
                    map (
                      member:
                      [ "${member.address}/128" ] ++ lib.optional (member.address4 != null) "${member.address4}/32"
                    ) (onHost vpn peer)
                  );
            };
            serverConfig = {
              Endpoint = "${peer.endpoint}:${toString vpn.port}";
            };
            clientConfig = {
              PersistentKeepalive = vpn.keepalive;
            };
          in
          base // (if peer.name == vpn.gateway then serverConfig else clientConfig)
        ) (lib.filter (peer: peer.name != host.name) (peers vpn));
      }
    );

    networks = lib.genAttrs' vpns (
      vpn:
      let
        network = host.network.${vpn.name};
      in
      lib.nameValuePair "30-${vpn.interface}" {
        matchConfig.Name = vpn.interface;
        address = [
          "${network.address}/${toString network.prefixLength}"
          "${network.address4}/${toString network.prefixLength4}"
        ];
        inherit (network) dns;
        routes =
          (lib.optionals (host.name == vpn.gateway) [
            {
              Destination = network.destination;
            }
            {
              Destination = network.destination4;
              Scope = "link";
            }
          ])
          ++ (lib.optionals (vpn.proxy && host.name != vpn.gateway) [
            {
              Gateway = org.host.${vpn.gateway}.network.${vpn.name}.address;
              Destination = "::/0";
              Metric = 2048;
            }
          ]);
        networkConfig = {
          DHCP = "no";
        };
      }
    );
  };
}
