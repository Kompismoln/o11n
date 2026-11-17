{
  name,
  config,
  lib,
  context,
  host,
  ...
}:
let
  router = if host.behind == null then null else context.org.host.${host.behind}.router;

  integer4 =
    address: lib.foldl (sum: octet: sum * 256 + lib.toInt octet) 0 (lib.splitString "." address);
  dotted4 =
    integer:
    lib.concatMapStringsSep "." (shift: toString (lib.mod (integer / shift) 256)) [
      16777216
      65536
      256
      1
    ];

  # Policy: a host is 10 past its id on its router's lan, clear of the router's address and of OpenWrt's DHCP pool.
  place =
    lib.throwIf (host.id == null)
      "host.${host.name}: its address on ${host.behind}'s lan derives from its id, which it has none of: give it an id."
      (10 + host.id);

  dhcp = lib.filter (network: network.mode == "dhcp" && network.metric != null) (
    lib.attrValues host.network
  );
  lowest = lib.foldl lib.min config.metric (map (network: network.metric) dhcp);
in
{
  options = {
    type = lib.mkOption {
      description = "network type";
      default = name;
      type = lib.types.str;
    };
    interface = lib.mkOption {
      description = "interface associated with the network";
      type = lib.types.str;
    };
    mode = lib.mkOption {
      description = "how the interface gets its address, statically or by dhcp; null leaves it unconfigured";
      type =
        with lib.types;
        nullOr (enum [
          "dhcp"
          "static"
        ]);
      default = null;
    };
    mac = lib.mkOption {
      description = "mac address";
      type = lib.types.nullOr context.types.mac;
      default = null;
    };
    address = lib.mkOption {
      description = "ipv6 host address (not CIDR)";
      type = with lib.types; nullOr str;
      default = null;
    };
    destination = lib.mkOption {
      description = "ipv6 destination";
      type = with lib.types; nullOr str;
      default = null;
    };
    prefixLength = lib.mkOption {
      description = "ipv6 prefix length";
      type = with lib.types; nullOr int;
      default = null;
    };
    gateway = lib.mkOption {
      description = "ipv6 gateway address";
      type = with lib.types; nullOr str;
      default = null;
    };
    metric = lib.mkOption {
      description = "ipv6 metric for routing: lower takes priority";
      type = with lib.types; nullOr int;
      default = 1024;
    };
    address4 = lib.mkOption {
      description = "ipv4 host address";
      type = with lib.types; nullOr str;
      default =
        if config.lan && router != null then
          dotted4 (integer4 router.address4 / router.size4 * router.size4 + place)
        else
          null;
      defaultText = lib.literalMD "on the `lan`, 10 past the host's id in its router's lan, or else null";
    };
    destination4 = lib.mkOption {
      description = "ipv4 destination";
      type = with lib.types; nullOr str;
      default = null;
    };
    gateway4 = lib.mkOption {
      description = "ipv4 gateway address";
      type = with lib.types; nullOr str;
      default = null;
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 prefix length";
      type = with lib.types; nullOr int;
      default = null;
    };
    metric4 = lib.mkOption {
      description = "ipv4 metric for routing: lower takes priority";
      type = with lib.types; nullOr int;
      default = config.metric;
    };
    dns = lib.mkOption {
      description = "name servers of the network";
      type = with lib.types; nullOr (listOf str);
      default = null;
    };
    fqdn = lib.mkOption {
      description = "host's name in the network";
      type = with lib.types; nullOr str;
      default = null;
    };
    principals = lib.mkOption {
      description = "the address and name of each principal that has one in the network on this host, by its id";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              description = "the principal's ipv6 address on this host in the network";
              type = lib.types.str;
            };
            fqdn = lib.mkOption {
              description = "the principal's name on this host in the network";
              type = lib.types.str;
            };
          };
        }
      );
      default = { };
    };
    gatewayOnLink = lib.mkEnableOption "onlink for gateway" // {
      type = with lib.types; nullOr bool;
      default = null;
    };
    suffix = lib.mkOption {
      description = "the ipv6 interface identifier, as ::fba, that a dhcp network forms its address with from the prefix its router advertises, rather than asking the router for one; null leaves it to the kernel and the router";
      type = with lib.types; nullOr (strMatching "::[0-9a-f]{1,4}(:[0-9a-f]{1,4}){0,3}");
      default = if config.lan then "::${toString place}" else null;
      defaultText = lib.literalMD "on the `lan`, `::` and 10 past the host's id, as the last octet of its `address4` reads, or else null";
      example = "::fba";
    };
    lan = lib.mkOption {
      description = "whether the router the host is `behind` reaches it on this network, the one it reserves its `address4` on and forwards to";
      type = lib.types.bool;
      default =
        host.behind != null
        && config.mode == "dhcp"
        && config.metric != null
        && config.metric == lowest
        && lib.count (network: network.metric == lowest) dhcp == 1;
      defaultText = lib.literalMD "for a host `behind` a router, whether this is its dhcp network with the lowest metric, if one network has it";
    };
    privacy = lib.mkEnableOption "ipv6 kernel address rotation" // {
      type = with lib.types; nullOr bool;
      default = null;
    };
  };
}
