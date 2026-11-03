{
  name,
  config,
  lib,
  context,
  ...
}:
{
  options = {
    enable = lib.mkEnableOption "a wireguard vpn" // {
      default = true;
    };
    id = lib.mkOption {
      description = "unique integer identifier for the vpn";
      type = lib.types.int;
    };
    ids = lib.mkOption {
      description = "entity id in various formats";
      type = context.types.ids.module;
      default = {
        int = config.id;
      };
      defaultText = lib.literalExpression "{ int = id; }";
    };
    name = lib.mkOption {
      description = "name of the vpn";
      type = lib.types.str;
      default = name;
    };
    trusted = lib.mkOption {
      description = "disable firewalls on this vpn";
      type = lib.types.bool;
    };
    address4 = lib.mkOption {
      description = "ipv4 vpn address";
      type = context.types.subnetCidr4;
      default = "${config.prefix4}.0/${toString config.prefixLength4}";
      defaultText = lib.literalExpression ''"''${prefix4}.0/''${toString prefixLength4}"'';
    };
    prefix4 = lib.mkOption {
      description = "ipv4 prefix for peers in vpn";
      type = context.types.subnetPrefix4;
      default = "${context.org.prefix4}.${toString config.id}";
      defaultText = lib.literalExpression ''"''${org.prefix4}.''${toString id}"'';
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 prefix length for peers in vpn";
      type = lib.types.int;
      default = context.org.prefixLength4;
    };
    address = lib.mkOption {
      description = "ipv6 vpn address";
      type = context.types.subnetCidr6;
      default = "${config.prefix}::/${toString config.prefixLength}";
      defaultText = lib.literalExpression ''"''${prefix}::/''${toString prefixLength}"'';
    };
    addressWithBrackets = lib.mkOption {
      description = "ipv6 vpn address enclosed in square brackets";
      type = context.types.subnetCidrBracketed6;
      readOnly = true;
      default = "[${config.prefix}::]/${toString config.prefixLength}";
      defaultText = lib.literalExpression ''"[''${prefix}::]/''${toString prefixLength}"'';
    };
    prefix = lib.mkOption {
      description = "ipv6 prefix for peers in vpn";
      type = context.types.subnetPrefix6;
      default = "${context.org.prefix}:${config.ids.hex4}";
      defaultText = lib.literalExpression ''"''${org.prefix}:''${ids.hex4}"'';
    };
    prefixLength = lib.mkOption {
      description = "ipv6 prefix length for peers in vpn";
      type = lib.types.int;
      default = context.org.prefixLength;
    };
    interface = lib.mkOption {
      description = "interface for the vpn";
      type = lib.types.str;
      default = name;
    };
    namespace = lib.mkOption {
      description = "top domain in the vpns";
      type = lib.types.str;
    };
    port = lib.mkOption {
      description = "port allocated for the vpn";
      type = lib.types.port;
      default = 51820 + config.id;
      defaultText = lib.literalExpression "51820 + id";
    };
    keepalive = lib.mkOption {
      description = "port allocated for the vpn";
      default = 25;
      type = lib.types.int;
    };
    gateway = lib.mkOption {
      description = "designated gateway host";
      type = context.types.host.ref;
    };
    proxy = lib.mkEnableOption "ipv6 proxy through gateway";
    dns = lib.mkOption {
      description = "list of name servers";
      type = lib.types.listOf context.types.host.ref;
    };
    resetOnRebuild = lib.mkOption {
      description = "destroy and recreate network device post rebuild";
      type = lib.types.bool;
      default = true;
    };
    key = lib.mkOption {
      description = "the key each host on the vpn has for it, its wireguard key";
      type = lib.types.str;
      readOnly = true;
      default = "${config.name}-key";
      defaultText = lib.literalExpression ''"''${name}-key"'';
    };
    members = lib.mkOption {
      description = "what has an address in the vpn, by its name there: each host on it, and each service that serves on it, on each of those hosts it's on";
      readOnly = true;
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              description = "the member's entity";
              type = lib.types.str;
            };
            host = lib.mkOption {
              description = "the host the member is on, whose wireguard key carries its traffic";
              type = lib.types.str;
            };
            address = lib.mkOption {
              description = "the member's ipv6 address";
              type = lib.types.str;
            };
            address4 = lib.mkOption {
              description = "the member's ipv4 address, which only a host has";
              type = lib.types.nullOr lib.types.str;
            };
            fqdn = lib.mkOption {
              description = "the member's name";
              type = lib.types.str;
            };
            key = lib.mkOption {
              description = "the member's own wireguard key, which only a host has";
              type = lib.types.nullOr lib.types.str;
            };
          };
        }
      );
      default =
        let
          hosts = lib.filter (host: lib.elem config.name host.vpns) (lib.attrValues context.org.host);
          services = lib.filter (service: service.vpn == config.name && service.principal != null) (
            lib.attrValues context.org.service
          );
        in
        lib.listToAttrs (
          map (host: {
            inherit (host) name;
            value = {
              id = host.handle;
              host = host.name;
              address = "${config.prefix}::${host.ids.hex4}";
              address4 = "${config.prefix4}.${host.ids.str}";
              fqdn = "${host.name}.${config.namespace}";
              inherit (config) key;
            };
          }) hosts
          ++ lib.concatMap (
            service:
            map
              (host: {
                name = "${service.name}-${host.name}";
                value = {
                  id = service.handle;
                  host = host.name;
                  address = "${config.prefix}:ffff:${host.ids.hex4}:${toString service.principal.uid}:${service.ids.hex4}";
                  address4 = null;
                  fqdn = "${service.name}-${host.name}.${config.namespace}";
                  key = null;
                };
              })
              (lib.filter (host: lib.any (principal: principal.handle == service.handle) host.principals) hosts)
          ) services
        );
      defaultText = lib.literalMD "each host whose `vpns` has the vpn, at `<prefix>::<host id>` and `<prefix4>.<host id>` as `<host>.<namespace>`, and each service whose `vpn` it is, on each of those hosts it's on, at `<prefix>:ffff:<host id>:<uid>:<id>` as `<service>-<host>.<namespace>`";
    };
    allowedTCPPorts = lib.mkOption {
      description = "force all peers to allow these tcp ports in the vpn";
      default = [ ];
      type = with lib.types; listOf int;
    };
    allowedUDPPorts = lib.mkOption {
      description = "force all peers to allow these udp ports in the vpn";
      default = [ ];
      type = with lib.types; listOf int;
    };
  };
}
