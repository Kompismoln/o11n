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
    lib.throwIfNot (lib.length suffixed == 1 && (lib.head suffixed).address4 != null)
      "${other.name} is behind ${host.name}, which reaches it on its one network with a suffix: give one network a suffix and an address4."
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

  # Policy: the router, which alone knows when its WAN address changes, updates the A records that name it, once its
  # WAN is up and every 15 minutes after, and only those that differ.
  glesys = lib.optionalAttrs (config.glesys != null) {
    "/etc/o11n/glesys" = ''
      #!/bin/sh
      set -u
      account=${lib.escapeShellArg config.glesys.account}
      key='@o11n-secret:${config.glesys.key}@'
      ip=$(ifstatus wan | jsonfilter -e '@["ipv4-address"][0].address')
      [ -n "$ip" ] || exit 0
      api() {
      	uclient-fetch -q -O - --user="$account" --password="$key" --header='Accept: application/json' \
      		--post-data="$2" "https://api.glesys.com/domain/$1"
      }
      for fqdn in ${lib.escapeShellArgs config.glesys.records}; do
      	name=''${fqdn%%.*}
      	domain=''${fqdn#*.}
      	records=$(api listrecords "domainname=$domain") || {
      		logger -t o11n-glesys "can't list the records of $domain: the API key has to let any address in, as the router's changes, and use the domain API"
      		continue
      	}
      	record="@.response.records[@.host=\"$name\" && @.type=\"A\"]"
      	id=$(echo "$records" | jsonfilter -e "$record.recordid")
      	data=$(echo "$records" | jsonfilter -e "$record.data")
      	if [ -z "$id" ]; then
      		logger -t o11n-glesys "$domain has no A record $name"
      	elif [ "$data" != "$ip" ]; then
      		api updaterecord "recordid=$id&data=$ip" >/dev/null &&
      			logger -t o11n-glesys "$fqdn is $ip, was $data" ||
      			logger -t o11n-glesys "can't update $fqdn to $ip"
      	fi
      done
    '';
    "/etc/hotplug.d/iface/90-o11n-glesys" = ''
      [ "$ACTION" = ifup ] && [ "$INTERFACE" = wan ] && sh /etc/o11n/glesys &
    '';
    "/etc/crontabs/root" = ''
      */15 * * * * sh /etc/o11n/glesys
    '';
  };

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
    # Policy: a reservation without a mac goes by the name the host asks with, which networkd sends.
    dhcp = map (
      other:
      section "o11n_${other.name}" "host" (
        {
          inherit (other) name;
          ip = (lan other).address4;
        }
        // lib.optionalAttrs ((lan other).mac != null) { inherit (lan other) mac; }
      )
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
    imageFiles = lib.mkOption {
      description = "the files the router's image holds: its `files` but those with a secret, which it has OpenWrt's own of until they're applied";
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.filterAttrs (_: text: !lib.hasInfix "@o11n-secret:" text) config.files;
      defaultText = lib.literalMD "its `files` without a secret in them";
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
        // glesys
        // {
          "/etc/dropbear/authorized_keys" = lib.concatMapStrings (
            user: builtins.readFile org.user.${user}.publicKeys.ssh-key
          ) (lib.filter (user: org.user.${user}.principal.hasPublicKey) host.users);
        };
      defaultText = lib.literalMD "each file of `uci`, and `system`, `dropbear` and those o11n derives sections of, rendered, and `/etc/dropbear/authorized_keys` from the ssh-keys of the host's users, and with `glesys` its updater";
    };
  };
}
