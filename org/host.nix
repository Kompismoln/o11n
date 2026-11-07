{
  lib,
  config,
  context,
  ...
}:
let
  inherit (context) org;
in
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "host";
  };

  options = {
    configurationFile = lib.mkOption {
      description = "path to specific configuration";
      type = lib.types.path;
      default = context.path + "/hosts/${config.name}/configuration.nix";
    };
    boot = lib.mkOption {
      description = "boot method";
      type = lib.types.enum [
        "grub"
        "systemd"
      ];
      default = "systemd";
    };
    hardwareReport = lib.mkOption {
      description = "hardware report method";
      type = lib.types.enum [
        "standard"
        "facter"
      ];
      default = "facter";
    };
    facterFile = lib.mkOption {
      description = "facter report path";
      default = context.path + "/hosts/${config.name}/facter.json";
      type = lib.types.path;
    };
    luksKeyFile = lib.mkOption {
      description = "path in the initrd to the key that unlocks the host's luks devices";
      type = lib.types.str;
      default = "/luks-key";
    };
    users = lib.mkOption {
      description = "users";
      type = lib.types.listOf context.types.user.ref;
    };
    roles = lib.mkOption {
      description = "roles that this host has";
      type = lib.types.listOf context.types.role.ref;
    };
    endpoint = lib.mkOption {
      description = "maybe canonical name on internet";
      default = null;
      type = with lib.types; nullOr str;
    };
    behind = lib.mkOption {
      description = "the router whose NAT the host is behind, a host with `openwrt`, which forwards to it the ports it listens on for its vpns, or null";
      type = lib.types.nullOr context.types.host.ref;
      default = null;
      apply =
        router:
        lib.throwIf (router != null && org.host.${router}.openwrt == null)
          "host.${config.name}.behind: ${router} is no router: give it openwrt, or set behind to one that has it."
          router;
    };
    openwrt = lib.mkOption {
      description = "the OpenWrt the host runs, as a router, or null";
      type = lib.types.nullOr (context.types.openwrt.module config);
      default = null;
    };
    vpns = lib.mkOption {
      description = "list of interface names for vpns";
      type = lib.types.listOf context.types.vpn.ref;
    };
    services = lib.mkOption {
      description = "the services of the host's roles, whose configuration it imports";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default = lib.attrValues (
        lib.genAttrs' (lib.concatMap (role: org.role.${role}.services) config.roles) (
          service: lib.nameValuePair service org.service.${service}
        )
      );
      defaultText = lib.literalMD "the `services` of its `roles`, in the order of their name";
    };
    principals = lib.mkOption {
      description = "the principals on the host: its users, the apps that run on it, and its roles' services and stores";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default = lib.attrValues (
        lib.filterAttrs (_: entity: entity.principal != null) (
          lib.listToAttrs (
            map (entity: lib.nameValuePair entity.handle entity) (
              map (user: org.user.${user}) config.users
              ++ lib.filter (app: lib.elem config.name app.run-on-hosts) (lib.attrValues org.app)
              ++ config.services
              ++ lib.concatMap (role: map (store: org.store.${store}) org.role.${role}.stores) config.roles
            )
          )
        )
      );
      defaultText = lib.literalMD "the host's `users`, the apps whose `run-on-hosts` has it, and the `services` and `stores` of its `roles`, but for those without a principal, in the order of their `handle`";
    };
    shares = lib.mkOption {
      description = "each host's first vpn it shares with this host, in the order of this host's vpns, or null";
      type = lib.types.lazyAttrsOf (lib.types.nullOr lib.types.str);
      readOnly = true;
      default = lib.mapAttrs (
        _: peer: lib.findFirst (vpn: lib.elem vpn peer.vpns) null config.vpns
      ) org.host;
      defaultText = lib.literalMD "for each host, the first of this host's `vpns` that is in its `vpns`, or `null`";
    };
    reach = lib.mkOption {
      description = "each host's network on the first vpn it shares with this host, in the order of this host's vpns, or null";
      type = lib.types.lazyAttrsOf (lib.types.nullOr lib.types.raw);
      readOnly = true;
      default = lib.mapAttrs (
        name: peer: if config.shares.${name} == null then null else peer.network.${config.shares.${name}}
      ) org.host;
    };
    system = lib.mkOption {
      description = "host platform";
      type = lib.types.str;
    };
    stateVersion = lib.mkOption {
      description = "nixos state version";
      type = with lib.types; nullOr str;
      default = null;
    };
    home = lib.mkOption {
      description = "list of home configurations for a user";
      default = { };
      type = lib.types.attrsOf (context.types.home.module config);
    };
    network = lib.mkOption {
      description = "networks to configure on host";
      default = { };
      type = lib.types.attrsOf context.types.network.module;
    };
    disk-layouts = lib.mkOption {
      description = "record of disk layouts that applies to host";
      default = { };
      type = lib.types.attrsOf context.types.disk.module;
    };
    desktop = lib.mkOption {
      description = "attrset of desktop settings";
      default = { };
      type = lib.types.attrsOf lib.types.anything;
    };
    monitors = lib.mkOption {
      description = "list of monitors possibly connected to the host";
      default = [ ];
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
    };
    devices = lib.mkOption {
      description = "list of devices possibly connected to the host";
      default = [ ];
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
    };
    rescueMode = lib.mkEnableOption "insecure rescue mode.";
    allotments = lib.mkOption {
      description = "the allotments on the host";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default = lib.filter (allotment: allotment.host == config.name) (lib.attrValues org.allotment);
      defaultText = lib.literalMD "the org's `allotment`s whose `host` is the host, in the order of their name";
    };
    replicas = lib.mkOption {
      description = "the allotments the host keeps a replica of";
      type = lib.types.listOf lib.types.raw;
      readOnly = true;
      default = lib.filter (allotment: lib.elem config.name allotment.replicas) (
        lib.attrValues org.allotment
      );
      defaultText = lib.literalMD "the org's `allotment`s whose `replicas` have the host, in the order of their name";
    };
    nixos = lib.mkOption {
      description = "whether o11n builds the host's NixOS system, rather than only its keys, vpns and homes";
      type = lib.types.bool;
      default = config.openwrt == null;
      defaultText = lib.literalExpression "openwrt == null";
    };
  };
  config = {
    keys =
      lib.genAttrs' config.vpns (vpn: lib.nameValuePair org.vpn.${vpn}.key "wireguard")
      // lib.genAttrs' (
        lib.filter (allotment: allotment.replicas != [ ]) config.allotments ++ config.replicas
      ) (allotment: lib.nameValuePair allotment.key "syncthing")
      // lib.optionalAttrs (lib.any (disk: disk.encrypted) (lib.attrValues config.disk-layouts)) {
        luks-key = "luks";
      };
    network = lib.genAttrs config.vpns (
      name:
      let
        vpn = org.vpn.${name};
        member = vpn.members.${config.name};
      in
      lib.mapAttrs (_: lib.mkDefault) {
        inherit (vpn) interface prefixLength prefixLength4;
        inherit (member) address address4 fqdn;
        mode = null;
        dns = lib.concatMap (dnsHost: [
          vpn.members.${dnsHost}.address
          vpn.members.${dnsHost}.address4
        ]) vpn.dns;
        destination = vpn.address;
        destination4 = vpn.address4;
        principals = lib.mapAttrs' (
          _: principal: lib.nameValuePair principal.id { inherit (principal) address fqdn; }
        ) (lib.filterAttrs (_: other: other.host == config.name && other.id != member.id) vpn.members);
      }
    );
  };
}
