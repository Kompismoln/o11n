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

  mesh = vpn: vpn.topology == "mesh";

  resolved =
    vpn:
    lib.filter (
      peer:
      lib.elem vpn.name peer.vpns && (mesh vpn || peer.name == vpn.gateway || host.name == vpn.gateway)
    ) (lib.attrValues org.host);

  routes = vpn: mesh vpn || host.name == vpn.gateway;

  listens = vpn: if mesh vpn then host.endpoint != null else host.name == vpn.gateway;

  # Policy: the host first, then its principals by name.
  onHost =
    vpn: peer:
    [ vpn.members.${peer.name} ]
    ++ lib.attrValues (
      lib.filterAttrs (name: member: member.host == peer.name && name != peer.name) vpn.members
    );

  isGateway = lib.any (vpn: !mesh vpn && host.name == vpn.gateway) vpns;
  dnsFor = lib.filter (vpn: lib.elem host.name vpn.dns) vpns;
  named = lib.filter (vpn: vpn.dns != [ ] && vpn.namespace != null) vpns;
  askedOf = lib.filter (vpn: !lib.elem host.name vpn.dns) named;
  proxyFor = lib.filter (vpn: host.name == vpn.gateway && vpn.proxy) vpns;
  proxied = vpn: !mesh vpn && vpn.proxy && host.name != vpn.gateway;

  # Policy: a host that proxies through a gateway does so in a table of its own, which it looks up after main and for
  # all but what its vpns send, marked, so that what a tunnel sends to its peer's endpoint never goes through another.
  tunnels = {
    mark = 28433;
    table = 28433;
    priority = 32800;
  };
  proxies = lib.any proxied vpns;
in
{

  services.kresd = lib.mkMerge [
    (lib.mkIf (dnsFor != [ ]) {
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
            ) (resolved vpn)
          ) dnsFor
        )}
      '';
    })
    # Policy: a kresd on the host, as its own vpns' name server or the mail server's resolver, asks each other vpn's name
    # servers for its namespace, as resolved does: Lix looks names up with `files dns` alone, which is /etc/resolv.conf,
    # the mail server's kresd where it runs.
    (lib.mkIf (config.services.kresd.enable && askedOf != [ ]) {
      extraConfig = lib.concatMapStrings (vpn: ''
        policy.add(policy.suffix(policy.STUB({${
          lib.concatMapStringsSep ", " (address: "'${address}'") host.network.${vpn.name}.dns
        }}), {todname('${vpn.namespace}.')}))
      '') askedOf;
    })
  ];

  systemd.services."systemd-networkd".preStop = lib.concatStringsSep "\n" (
    map (vpn: "${pkgs.iproute2}/bin/ip link delete ${vpn.interface}") (
      lib.filter (vpn: vpn.resetOnRebuild) vpns
    )
  );

  networking = {
    # Policy: on a vpn without name servers, as a mesh, a host has in /etc/hosts itself and what it reaches there.
    hosts = lib.mkMerge (
      lib.concatMap (
        vpn:
        lib.concatMap (
          peer:
          lib.concatMap (
            member:
            map (address: { ${address} = [ member.fqdn ]; }) (
              lib.filter (address: address != null) [
                member.address
                member.address4
              ]
            )
          ) (onHost vpn org.host.${peer})
        ) ([ host.name ] ++ vpn.reaches.${host.name})
      ) (lib.filter (vpn: vpn.dns == [ ]) vpns)
    );
    wireguard.enable = true;
    networkmanager.unmanaged = map (interface: "interface-name:${interface}") host.vpns;

    nat = lib.mkIf (proxyFor != [ ]) {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = map (vpn: vpn.interface) proxyFor;
      externalInterface = host.network.eth.interface;
    };

    firewall = {
      allowedUDPPorts = map (vpn: vpn.members.${host.name}.port) (lib.filter listens vpns);
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

  assertions =
    lib.concatMap (
      vpn:
      let
        named = lib.optional (vpn.gateway != null) vpn.gateway ++ vpn.dns;
      in
      [
        {
          assertion = lib.all (other: lib.elem vpn.name org.host.${other}.vpns) named;
          message = "vpn.${vpn.name}'s gateway and dns are hosts on it: add ${vpn.name} to the vpns of ${
            lib.concatStringsSep ", " (lib.filter (other: !lib.elem vpn.name org.host.${other}.vpns) named)
          }.";
        }
        {
          assertion = mesh vpn -> vpn.gateway == null && !vpn.proxy;
          message = "vpn.${vpn.name} is a mesh, which has no gateway to forward or proxy through: remove its gateway and proxy, or set topology = \"hub\".";
        }
        {
          assertion = mesh vpn || vpn.gateway != null;
          message = "vpn.${vpn.name} is a hub, whose hosts peer through its gateway: set its gateway to a host on it.";
        }
      ]
    ) vpns
    ++ (
      let
        ports = map (vpn: vpn.members.${host.name}.port) (lib.filter listens vpns);
      in
      [
        {
          assertion = lib.allUnique ports;
          message = "${host.name} listens on ${
            lib.concatMapStringsSep ", " toString (
              lib.unique (lib.filter (port: lib.count (other: other == port) ports > 1) ports)
            )
          } for more than one of its vpns: set the port of one of them apart.";
        }
      ]
    );

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
          ListenPort = lib.mkIf (listens vpn) vpn.members.${host.name}.port;
          FirewallMark = lib.mkIf proxies tunnels.mark;
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
            dials = {
              Endpoint = "${peer.endpoint}:${toString vpn.members.${peer.name}.port}";
            };
            keepsAlive = {
              PersistentKeepalive = vpn.keepalive;
            };
          in
          # Policy: on a mesh, a host without an endpoint dials each peer that has one and keeps its NAT's mapping open
          # for the replies; a peer without one dials it.
          if mesh vpn then
            base
            // lib.optionalAttrs (peer.endpoint != null) dials
            // lib.optionalAttrs (host.endpoint == null) keepsAlive
          # Policy: on a hub, both keep alive: a client, as a gateway whose interface was recreated knows no client's
          # endpoint until it hears from it; the gateway, so that a client whose dialed address went stale follows it to
          # where it sends from.
          else
            base // keepsAlive // lib.optionalAttrs (peer.name == vpn.gateway) dials
        ) (map (peer: org.host.${peer}) vpn.peers.${host.name});
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
        # Policy: a vpn's name servers answer for its namespace alone, and are asked nothing else.
        domains = lib.mkIf (lib.elem vpn named) [ "~${vpn.namespace}" ];
        routes =
          (lib.optionals (routes vpn) [
            {
              Destination = network.destination;
            }
            {
              Destination = network.destination4;
              Scope = "link";
            }
          ])
          ++ (lib.optionals (proxied vpn) [
            {
              Gateway = org.host.${vpn.gateway}.network.${vpn.name}.address;
              Destination = "::/0";
              Table = tunnels.table;
            }
          ]);
        routingPolicyRules = lib.optionals (proxied vpn) [
          {
            Family = "ipv6";
            FirewallMark = tunnels.mark;
            InvertRule = true;
            Table = tunnels.table;
            Priority = tunnels.priority;
          }
        ];
        networkConfig = {
          DHCP = "no";
        };
      }
    );
  };
}
