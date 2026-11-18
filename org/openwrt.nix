{
  config,
  lib,
  context,
  host,
  ...
}:
let
  inherit (host) router;

  glesysOf = if router == null then null else router.glesys;

  at = "host.${host.name}.openwrt.uci";

  named = name: builtins.match "[A-Za-z0-9_]+" name != null;

  indexed = name: builtins.match "@[A-Za-z0-9_-]+\\[-?[0-9]+]" name != null;

  scalar =
    path: value:
    if lib.isBool value then
      (if value then "1" else "0")
    else if lib.isAttrs value then
      lib.throwIfNot (value ? secret && host.keys ? ${value.secret})
        "${at}: ${path} is { secret = <key> } with a key of ${host.name}'s own: declare it under keys."
        "@o11n-secret:${value.secret}@"
    else
      toString value;

  # Policy: a named section is set with its type, which creates it or keeps its options, and @<type>[<index>] is one
  # the router already has; a list is set anew, and _delete deletes the section.
  commands =
    file:
    { name, options }:
    let
      path = "${file}.${name}";
      own = removeAttrs options [
        "_type"
        "_delete"
      ];
      set =
        option: value:
        "uci set ${lib.escapeShellArg "${path}.${option}=${scalar "${path}.${option}" value}"}";
    in
    lib.throwIfNot (named name || indexed name)
      "${at}.${file}: ${name} is neither a section's name nor @<type>[<index>]: rename it."
      (
        if options._delete or false then
          lib.throwIf (own != { } || options ? _type)
            "${at}.${file}.${name}: _delete deletes the section, which has nothing else then: drop the rest."
            [ "uci -q delete ${lib.escapeShellArg path} || :" ]
        else
          lib.throwIf (named name && !(options ? _type))
            "${at}.${file}.${name}: a named section is set with its type: give it _type."
            (
              lib.throwIf (indexed name && options ? _type)
                "${at}.${file}.${name}: the index names a section the router has, of the type it says: drop _type."
                (
                  lib.optional (options ? _type) "uci set ${lib.escapeShellArg "${path}=${options._type}"}"
                  ++ lib.concatLists (
                    lib.mapAttrsToList (
                      option: value:
                      lib.throwIfNot (named option) "${at}.${file}.${name}: ${option} is no option's name: rename it." (
                        if lib.isList value then
                          [ "uci -q delete ${lib.escapeShellArg "${path}.${option}"} || :" ]
                          ++ map (
                            item: "uci add_list ${lib.escapeShellArg "${path}.${option}=${scalar "${path}.${option}" item}"}"
                          ) value
                        else
                          [ (set option value) ]
                      )
                    ) own
                  )
                )
            )
      );

  section = name: options: { inherit name options; };

  # Policy: UCI names a section by [A-Za-z0-9_] alone, and o11n names its own by hosts and vpns, which may have more.
  o11nName = name: "o11n_${lib.stringAsChars (char: if named char then char else "_") name}";

  # Policy: o11n's sections go before a reapply and come back in its order after the router's own, as fw4 matches
  # redirects in order.
  forget = file: ''
    for section in $(uci -q show ${file} | sed -n 's/^${file}\.\(o11n_[A-Za-z0-9_]*\)=.*/\1/p'); do
    	uci delete "${file}.$section"
    done
  '';

  noSecret = _: text: !lib.hasInfix "@o11n-secret:" text;

  script = changes: "set -eu\n" + lib.concatStrings (lib.attrValues changes) + "uci commit\n";

  # Policy: the router updates the records, as it alone knows when its WAN address and the prefix it delegates change.
  byDomain = lib.optionalAttrs (glesysOf != null) (
    lib.mapAttrs (_: fqdns: map (fqdn: lib.head (lib.splitString "." fqdn)) fqdns) (
      lib.groupBy (fqdn: lib.concatStringsSep "." (lib.tail (lib.splitString "." fqdn))) glesysOf.records
    )
  );

  keepLine =
    domain: name: type: given: address:
    "\t[ -z \"\$${given}\" ] || keep ${
      lib.escapeShellArgs [
        domain
        name
        type
      ]
    } \"${address}\"\n";

  glesys = lib.optionalAttrs (glesysOf != null) {
    "/etc/o11n/glesys" = ''
      #!/bin/sh
      set -u
      key='@o11n-secret:${glesysOf.key}@'
      # Fact: GleSYS answers uclient-fetch's --user and --password with 401, and a Basic header with the same with 200.
      auth=$(ucode -e 'print(b64enc(ARGV[0] + ":" + ARGV[1]))' -- ${lib.escapeShellArg glesysOf.account} "$key")
      wan=$(ifstatus wan 2>/dev/null) || wan='{}'
      wan6=$(ifstatus wan6 2>/dev/null) || wan6='{}'
      ip=$(ucode -e 'print(json(ARGV[0])["ipv4-address"]?.[0]?.address ?? "")' -- "$wan")
      # Fact: the lan's /64, which odhcpd advertises, is the first of what the router assigns the lan of its prefix.
      prefix=$(ucode -e 'print(json(ARGV[0])["ipv6-prefix"]?.[0]?.assigned?.lan?.address ?? "")' -- "$wan6")
      [ -n "$ip$prefix" ] || exit 0
      api() {
      	uclient-fetch -q -O - --header="Authorization: Basic $auth" --header='Accept: application/json' \
      		--post-data="$2" "https://api.glesys.com/domain/$1"
      }
      six() {
      	ucode -e 'let p = iptoarr(ARGV[0]), s = iptoarr(ARGV[1]); print(arrtoip(map(p, (b, i) => b | s[i])))' -- "$prefix" "$1"
      }
      # Policy: an address GleSYS has is compared as the router writes one, so that another form of it isn't a change.
      keep() {
      	found=$(ucode -e '
      		for (let r in json(ARGV[0]).response?.records ?? [])
      			if (r.host == ARGV[1] && r.type == ARGV[2]) { print(r.recordid, " ", arrtoip(iptoarr(r.data)) ?? r.data, "\n"); break; }
      	' -- "$records" "$2" "$3")
      	id=''${found%% *}
      	data=''${found#* }
      	if [ -z "$found" ]; then
      		logger -t o11n-glesys "$1 has no $3 record $2"
      	elif [ "$data" != "$4" ]; then
      		api updaterecord "recordid=$id&data=$4" >/dev/null &&
      			logger -t o11n-glesys "$2.$1 $3 is $4, was $data" ||
      			logger -t o11n-glesys "updating $2.$1 $3 to $4 failed"
      	fi
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (domain: names: ''
          if records=$(api listrecords ${lib.escapeShellArg "domainname=${domain}"}); then
          ${
            lib.concatMapStrings (
              name:
              keepLine domain name "A" "ip" "$ip"
              + lib.optionalString (glesysOf.records6 ? "${name}.${domain}") (
                keepLine domain name "AAAA" "prefix"
                  "$(six ${lib.escapeShellArg glesysOf.records6."${name}.${domain}"})"
              )
            ) names
          }else
          	logger -t o11n-glesys "listing the records of ${domain} failed"
          fi
        '') byDomain
      )}'';
    "/etc/hotplug.d/iface/90-o11n-glesys" = ''
      case "$ACTION:$INTERFACE" in
      ifup:wan | ifup:wan6 | ifupdate:wan6) sh /etc/o11n/glesys & ;;
      esac
    '';
    "/etc/crontabs/root" = ''
      */15 * * * * sh /etc/o11n/glesys
    '';
  };

  lan = other: router.lan.${other};

  derived = {
    system = [ (section "@system[0]" { hostname = host.name; }) ];
    dropbear = [
      (section "@dropbear[0]" (
        {
          PasswordAuth = false;
          RootPasswordAuth = false;
          Port = 22;
        }
        # Policy: a router takes logins on its lan alone, whatever its firewall lets in from its WAN.
        // lib.optionalAttrs (router != null) { Interface = "lan"; }
      ))
    ];
  }
  // lib.optionalAttrs (router != null) {
    network = [
      (section "lan" {
        _type = "interface";
        ipaddr = [ "${router.address4}/${toString router.prefixLength4}" ];
      })
    ];
    # Policy: a reservation without a mac goes by the name the host asks with, which networkd sends.
    dhcp = lib.mapAttrsToList (
      other: network:
      section (o11nName other) (
        {
          _type = "host";
          name = other;
          ip = network.address4;
        }
        // lib.optionalAttrs (network.mac != null) { inherit (network) mac; }
      )
    ) router.lan;
    firewall =
      lib.concatMap (forward: [
        (section (o11nName "${forward.host}_${forward.vpn}") {
          _type = "redirect";
          name = "${forward.host}-${forward.vpn}";
          src = "wan";
          dest = "lan";
          proto = "udp";
          src_dport = forward.port;
          dest_ip = (lan forward.host).address4;
          dest_port = forward.port;
          family = "ipv4";
          target = "DNAT";
        })
        (section (o11nName "${forward.host}_${forward.vpn}_6") {
          _type = "rule";
          name = "${forward.host}-${forward.vpn}-ipv6";
          src = "wan";
          dest = "lan";
          proto = "udp";
          dest_ip = "${(lan forward.host).suffix}/::ffff:ffff:ffff:ffff";
          dest_port = forward.port;
          family = "ipv6";
          target = "ACCEPT";
        })
      ]) router.forwards
      ++ lib.concatMap (
        exposed:
        let
          named = "${exposed.host}_${exposed.name}";
        in
        lib.optionals exposed.ipv4 (
          map (
            port:
            section (o11nName "${named}_${toString port}") {
              _type = "redirect";
              name = "${exposed.host}-${exposed.name}-${toString port}";
              src = "wan";
              dest = "lan";
              inherit (exposed) proto;
              src_dport = port;
              dest_ip = (lan exposed.host).address4;
              dest_port = port;
              family = "ipv4";
              target = "DNAT";
            }
          ) exposed.ports
        )
        ++ [
          (section (o11nName "${named}_6") {
            _type = "rule";
            name = "${exposed.host}-${exposed.name}-ipv6";
            src = "wan";
            dest = "lan";
            inherit (exposed) proto;
            dest_ip = "${(lan exposed.host).suffix}/::ffff:ffff:ffff:ffff";
            dest_port = exposed.ports;
            family = "ipv6";
            target = "ACCEPT";
          })
        ]
      ) router.exposes
      ++ lib.optional (router.dmz != null) (
        section (o11nName "dmz") {
          _type = "redirect";
          name = "dmz-${router.dmz}";
          src = "wan";
          dest = "lan";
          proto = "tcp udp";
          dest_ip = (lan router.dmz).address4;
          family = "ipv4";
          target = "DNAT";
        }
      );
  };

  forgotten = [
    "dhcp"
    "firewall"
  ];
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
    uci = lib.mkOption {
      description = "what the host changes of OpenWrt's own UCI, by file, by section, a section's name or @<type>[<index>], with a named section's type as `_type`, or `_delete = true` to delete it: a list is set anew, and `{ secret = <key> }` is a key of the host's, which is written in when applied; o11n adds the sections it derives, whose names start with `o11n_`";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.anything));
      default = { };
    };
    changes = lib.mkOption {
      description = "for each UCI file, the commands that change it: the host's `uci`, in the order of its sections' names, then o11n's, which removes the sections it named before";
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default =
        lib.genAttrs (lib.unique (lib.attrNames config.uci ++ lib.attrNames derived ++ forgotten))
          (
            file:
            let
              own = config.uci.${file} or { };
            in
            lib.throwIf (lib.any (lib.hasPrefix "o11n_") (lib.attrNames own))
              "${at}.${file}: a section's name starts with o11n_, which o11n's are named by: rename it."
              (
                lib.optionalString (lib.elem file forgotten) (forget file)
                + lib.concatLines (
                  lib.concatMap (commands file) (lib.mapAttrsToList section own ++ derived.${file} or [ ])
                )
              )
          );
      defaultText = lib.literalMD "for each file of `uci`, and `system`, `dropbear`, `dhcp` and `firewall`, the commands of `uci` and of the sections o11n derives";
    };
    imageFiles = lib.mkOption {
      description = "the files the router's image holds: its `files` but those with a secret, and instead of `/etc/o11n/uci`, `/etc/uci-defaults/99-o11n`, which makes the changes of each file without a secret at first boot";
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.filterAttrs noSecret (removeAttrs config.files [ "/etc/o11n/uci" ]) // {
        "/etc/uci-defaults/99-o11n" = script (lib.filterAttrs noSecret config.changes);
      };
      defaultText = lib.literalMD "its `files` without a secret in them or `/etc/o11n/uci`, and `/etc/uci-defaults/99-o11n` with the `changes` that have none";
    };
    files = lib.mkOption {
      description = "the files o11n writes on the router, by path: `/etc/o11n/uci`, a script that makes all `changes` and commits them, the ssh-keys root takes, its users' and service-rescue's, and with a router's `glesys` its updater";
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = {
        "/etc/o11n/uci" = script config.changes;
        "/etc/dropbear/authorized_keys" = lib.concatMapStrings builtins.readFile (
          map (user: context.org.user.${user}.publicKeys.ssh-key) (
            lib.filter (user: context.org.user.${user}.principal.hasPublicKey) host.users
          )
          ++ lib.optional (context.org.service ? rescue) context.org.service.rescue.publicKeys.ssh-key
        );
      }
      // glesys;
      defaultText = lib.literalMD "`/etc/o11n/uci` from `changes`, `/etc/dropbear/authorized_keys` from the ssh-keys of the host's users and service-rescue, and with a router's `glesys` its updater";
    };
  };
}
