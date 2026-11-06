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

  lan =
    other:
    let
      suffixed = lib.filter (network: network.suffix != null) (lib.attrValues other.network);
    in
    lib.throwIfNot
      (
        lib.length suffixed == 1 && (lib.head suffixed).mac != null && (lib.head suffixed).address4 != null
      )
      "${other.name} is behind ${host.name}, which reaches it on its one network with a suffix: give one network a suffix, a mac and an address4."
      (lib.head suffixed);

  # Policy: a section is its name, its type and its options, in the order the file has them, as fw4 matches redirects.
  section = name: type: options: { inherit name type options; };

  # Policy: a section o11n derives under the name of one of the router's takes its place, with the router's options
  # under its own.
  merge =
    own: theirs:
    map (
      section:
      let
        same = lib.findFirst (other: other.name == section.name) null theirs;
      in
      if same == null then section else same // { options = section.options // same.options; }
    ) own
    ++ lib.filter (section: !lib.any (other: other.name == section.name) own) theirs;

  sections =
    file:
    lib.mapAttrsToList (
      name: options: section name options._type (removeAttrs options [ "_type" ])
    ) file;

  render =
    let
      quote = value: "'${lib.replaceStrings [ "'" ] [ "'\\''" ] value}'";
      scalar =
        name: value:
        if lib.isBool value then
          (if value then "1" else "0")
        else if lib.isAttrs value then
          lib.throwIfNot (value ? secret && host.keys ? ${value.secret})
            "host.${host.name}.openwrt.uci: ${name} is { secret = <key> } with a key of ${host.name}'s own: declare it under keys."
            "@o11n-secret:${value.secret}@"
        else
          toString value;
      option =
        name: value:
        if lib.isList value then
          lib.concatMapStrings (item: "\tlist ${name} ${quote (scalar name item)}\n") value
        else
          "\toption ${name} ${quote (scalar name value)}\n";
    in
    list:
    lib.concatMapStringsSep "\n" (
      section:
      "config ${section.type} ${quote section.name}\n"
      + lib.concatStrings (lib.mapAttrsToList option section.options)
    ) list;

  # Policy: what a host behind the router listens on is forwarded to it on IPv4 and let in on IPv6, ahead of a dmz.
  forwards = lib.concatMap (
    other:
    lib.concatMap (
      vpn:
      let
        port = org.vpn.${vpn}.members.${other.name}.port;
      in
      lib.optional (port != null) {
        host = other.name;
        inherit vpn port;
      }
    ) other.vpns
  ) behind;

  derived = {
    system = [
      (section "system" "system" { hostname = host.name; })
    ];
    dropbear = [
      (section "main" "dropbear" {
        PasswordAuth = false;
        RootPasswordAuth = false;
        Port = 22;
      })
    ];
    dhcp = map (
      other:
      section "o11n_${other.name}" "host" {
        inherit (other) name;
        inherit (lan other) mac;
        ip = (lan other).address4;
      }
    ) behind;
    firewall =
      lib.concatMap (forward: [
        (section "o11n_${forward.host}_${forward.vpn}" "redirect" {
          name = "${forward.host}-${forward.vpn}";
          src = "wan";
          dest = "lan";
          proto = "udp";
          src_dport = forward.port;
          dest_ip = (lan org.host.${forward.host}).address4;
          dest_port = forward.port;
          family = "ipv4";
          target = "DNAT";
        })
        (section "o11n_${forward.host}_${forward.vpn}_6" "rule" {
          name = "${forward.host}-${forward.vpn}-ipv6";
          src = "wan";
          dest = "lan";
          proto = "udp";
          dest_ip = "${(lan org.host.${forward.host}).suffix}/::ffff:ffff:ffff:ffff";
          dest_port = forward.port;
          family = "ipv6";
          target = "ACCEPT";
        })
      ]) forwards
      ++ lib.optional (config.dmz != null) (
        section "o11n_dmz" "redirect" {
          name = "dmz-${config.dmz}";
          src = "wan";
          dest = "lan";
          proto = "tcp udp";
          dest_ip = (lan org.host.${config.dmz}).address4;
          family = "ipv4";
          target = "DNAT";
        }
      );
  };
in
{
  options = {
    release = lib.mkOption {
      description = "the OpenWrt release the router runs";
      type = lib.types.str;
      example = "25.12.6";
    };
    target = lib.mkOption {
      description = "the router's OpenWrt target, as its downloads name it";
      type = lib.types.str;
      example = "ath79/generic";
    };
    profile = lib.mkOption {
      description = "the router's OpenWrt profile, as the target's profiles.json names it";
      type = lib.types.str;
      example = "netgear_wndr3700";
    };
    packages = lib.mkOption {
      description = "the packages the router's image has besides its profile's, or leaves out of them, as -<package>";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    dmz = lib.mkOption {
      description = "the host behind the router that what isn't forwarded otherwise is forwarded to on IPv4, or null";
      type = lib.types.nullOr context.types.host.ref;
      default = null;
    };
    uci = lib.mkOption {
      description = "the router's own UCI, by file, by section name, with the section's type as `_type`: a list is a `list`, and `{ secret = <key> }` a key of the host's, which is written in when applied; o11n adds the sections it derives, whose names start with `o11n_`, and its options to the sections `system.system` and `dropbear.main`";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.anything));
      default = { };
    };
    files = lib.mkOption {
      description = "the files o11n writes on the router, by path: each `/etc/config/` file whole, the router's own sections first, in the order of their names, and those o11n derives after, in its order";
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default =
        let
          names = lib.unique (lib.attrNames config.uci ++ lib.attrNames derived);
        in
        lib.genAttrs' names (
          file:
          lib.nameValuePair "/etc/config/${file}" (
            render (
              lib.throwIf (lib.any (lib.hasPrefix "o11n_") (lib.attrNames (config.uci.${file} or { })))
                "host.${host.name}.openwrt.uci.${file}: a section's name starts with o11n_, which o11n's are named by: rename it."
                (merge (sections (config.uci.${file} or { })) (derived.${file} or [ ]))
            )
          )
        )
        // {
          "/etc/dropbear/authorized_keys" = lib.concatMapStrings (
            user: builtins.readFile org.user.${user}.publicKeys.ssh-key
          ) (lib.filter (user: org.user.${user}.principal.hasPublicKey) host.users);
        };
      defaultText = lib.literalMD "each file of `uci`, and `system`, `dropbear` and those o11n derives sections of, rendered, and `/etc/dropbear/authorized_keys` from the ssh-keys of the host's users";
    };
  };
}
