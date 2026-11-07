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
      description = "for each host behind the router, the network the router reaches it on: its one network with a `suffix`, which has an `address4`";
      type = lib.types.lazyAttrsOf lib.types.raw;
      readOnly = true;
      default = lib.genAttrs' behind (
        other:
        let
          suffixed = lib.filter (network: network.suffix != null) (lib.attrValues other.network);
        in
        lib.nameValuePair other.name (
          lib.throwIfNot (lib.length suffixed == 1 && (lib.head suffixed).address4 != null)
            "${other.name} is behind ${host.name}, which reaches it on its one network with a suffix: give one network a suffix and an address4."
            (
              let
                network = lib.head suffixed;
                size = lib.foldl (product: _: product * 2) 1 (lib.range 1 (32 - config.prefixLength4));
                inside =
                  integer4 network.address4 / size == integer4 config.address4 / size
                  && network.address4 != config.address4;
              in
              lib.throwIfNot inside
                "${other.name}'s address4 ${network.address4} isn't in ${host.name}'s lan, ${config.address4}/${toString config.prefixLength4}: give it one there, or set the router's address4 and prefixLength4."
                network
            )
        )
      );
      defaultText = lib.literalMD "for each host whose `behind` is the router, its one network with a `suffix`";
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
  };
}
