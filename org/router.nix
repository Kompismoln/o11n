{
  config,
  lib,
  context,
  host,
  ...
}:
let
  inherit (context) org;

  behind = lib.filter (other: other.behind == host.name) (lib.attrValues org.host);

  integer4 =
    address: lib.foldl (sum: octet: sum * 256 + lib.toInt octet) 0 (lib.splitString "." address);

  runs = other: name: lib.any (service: service.name == name) other.services;

  # Dependency: roles/app-scheduler.nix serves a host's apps of a kind through nixos/nginx.nix, as
  # nixos/services/nix-remote.nix and nixos/services/remote-builder-relay.nix serve themselves, on ports 80 and 443.
  serving = lib.filter (
    other:
    (
      lib.elem "app-scheduler" other.roles
      && lib.any (app: app.kind != null && lib.elem other.name app.run-on-hosts) (lib.attrValues org.app)
    )
    || runs other "nix-remote"
    || runs other "remote-builder-relay"
  ) behind;

  # Dependency: nixos/services/torrent-server.nix takes peers on the host's peerPort, 51413 for a host it has none for.
  seeding = lib.filter (other: runs other "torrent-server") behind;
  peerPort =
    other: (org.service.torrent-server.hosts.${other.name} or { peerPort = 51413; }).peerPort;
in
{
  options = {
    address4 = lib.mkOption {
      description = "the router's IPv4 address on its lan, which o11n reaches it at where its name doesn't answer";
      type = context.types.host4;
      default = "192.168.1.1";
    };
    prefixLength4 = lib.mkOption {
      description = "the prefix length of the router's lan, which each host behind it has its address4 in";
      type = lib.types.ints.between 8 30;
      default = 24;
    };
    size4 = lib.mkOption {
      description = "the number of addresses in the router's lan";
      internal = true;
      readOnly = true;
      type = lib.types.int;
      default = lib.foldl (product: _: product * 2) 1 (lib.range 1 (32 - config.prefixLength4));
      defaultText = lib.literalMD "2 to the power of 32 less `prefixLength4`";
    };
    web = lib.mkOption {
      description = "the host behind the router that it forwards ports 80 and 443 to on IPv4, which one address has but once, or null";
      type = lib.types.nullOr context.types.host.ref;
      default =
        if lib.length serving > 1 then
          throw "host.${host.name}.router.web: ${
            lib.concatMapStringsSep " and " (other: other.name) serving
          } each serve the web behind ${host.name}, which forwards ports 80 and 443 on IPv4 to one of them: set its web to one."
        else if serving == [ ] then
          null
        else
          (lib.head serving).name;
      defaultText = lib.literalMD "the one host behind the router that serves the web, as an app of a kind on an app-scheduler does, or a nix-remote or remote-builder-relay";
      apply =
        web:
        lib.throwIf (web != null && org.host.${web}.behind != host.name)
          "host.${host.name}.router.web: ${web} isn't behind ${host.name}: set its behind to ${host.name}, or the web to a host that is."
          web;
    };
    dmz = lib.mkOption {
      description = "the host behind the router that what isn't forwarded otherwise is forwarded to on IPv4, or null";
      type = lib.types.nullOr context.types.host.ref;
      default = null;
      apply =
        dmz:
        lib.throwIf (dmz != null && org.host.${dmz}.behind != host.name)
          "host.${host.name}.router.dmz: ${dmz} isn't behind ${host.name}: set its behind to ${host.name}, or the dmz to a host that is."
          dmz;
    };
    glesys = lib.mkOption {
      description = "the GleSYS account whose DNS the router keeps its WAN address in, as the A record of each of `records`, or null";
      default = null;
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            account = lib.mkOption {
              description = "the account, as GleSYS names it";
              type = lib.types.str;
              example = "CL12345";
            };
            key = lib.mkOption {
              description = "the host's secret that is the account's API key, which may update its DNS records";
              type = lib.types.str;
              default = "glesys-key";
            };
            records = lib.mkOption {
              description = "the names whose A record is the router's WAN address, each `<name>.<domain>` of a domain of the account's";
              type = lib.types.listOf (lib.types.strMatching "[a-z0-9-]+\\.[a-z0-9.-]+");
              default = lib.filter (endpoint: endpoint != null) (map (other: other.endpoint) behind);
              defaultText = lib.literalMD "the `endpoint` of each host behind the router that has one";
            };
          };
        }
      );
    };
    lan = lib.mkOption {
      description = "for each host behind the router, the network the router reaches it on: its one network with `lan`, which has a `suffix` and an `address4`";
      type = lib.types.lazyAttrsOf lib.types.raw;
      readOnly = true;
      default = lib.genAttrs' behind (
        other:
        let
          lanned = lib.filter (network: network.lan) (lib.attrValues other.network);
        in
        lib.nameValuePair other.name (
          lib.throwIfNot
            (lib.length lanned == 1 && (lib.head lanned).suffix != null && (lib.head lanned).address4 != null)
            "${other.name} is behind ${host.name}, which reaches it on its one network with lan, its dhcp network with the lowest metric by default, with a suffix and an address4: set lan on one of its dhcp networks."
            (
              let
                network = lib.head lanned;
                size = config.size4;
                offset = lib.mod (integer4 network.address4) size;
                inside =
                  integer4 network.address4 / size == integer4 config.address4 / size
                  && network.address4 != config.address4
                  && offset != 0
                  && offset != size - 1;
              in
              lib.throwIfNot inside
                "${other.name}'s address4 ${network.address4} isn't in ${host.name}'s lan, ${config.address4}/${toString config.prefixLength4}: give it one there, or set the router's address4 and prefixLength4."
                network
            )
        )
      );
      defaultText = lib.literalMD "for each host whose `behind` is the router, its one network with `lan`";
    };
    forwards = lib.mkOption {
      description = "the ports the router forwards, each `{ host, vpn, port }`: each port a host behind it listens on for its vpns";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default = lib.concatMap (
        other:
        lib.concatMap (
          vpn:
          let
            inherit (org.vpn.${vpn}.members.${other.name}) port;
          in
          lib.optional (port != null) {
            host = other.name;
            inherit vpn port;
          }
        ) other.vpns
      ) behind;
      defaultText = lib.literalMD "each port that a host whose `behind` is the router listens on for its `vpns`, in the order of the hosts' names and their vpns";
    };
    exposes = lib.mkOption {
      description = "what the router lets in to the hosts behind it beyond their vpns, each `{ host, name, proto, ports, ipv4 }`: ports 80 and 443 to each host that serves the web, on IPv4 to `web` alone, and to a torrent-server its peerPort";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default =
        map (other: {
          host = other.name;
          name = "web";
          proto = "tcp";
          ports = [
            80
            443
          ];
          ipv4 = other.name == config.web;
        }) serving
        ++ map (other: {
          host = other.name;
          name = "torrent";
          proto = "tcp udp";
          ports = [ (peerPort other) ];
          ipv4 = true;
        }) seeding;
      defaultText = lib.literalMD "the web to each host behind the router that serves it, and each torrent-server's peerPort";
    };
  };
}
