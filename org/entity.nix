{
  name,
  lib,
  config,
  context,
  ...
}:
{
  config = {
    keys = context.classes.${config.class}.keys;
    publicKeys = lib.mapAttrs (
      key: _:
      lib.mkDefault (
        context.path
        + "/public-keys/${config.handle}-${key}.${
          {
            tls-cert = "pem";
            passwd = "sha512";
            archive-passwd = "htpasswd";
          }
          .${key} or "pub"
        }"
      )
    ) config.keys;
  };

  options = {
    id = lib.mkOption {
      description = "numeric internal id used to seed other id's";
      default = null;
      type = with lib.types; nullOr int;
    };
    name = lib.mkOption {
      description = "name";
      default = name;
      type = lib.types.str;
    };
    class = lib.mkOption {
      description = "entity class";
      type = context.types.class;
    };
    handle = lib.mkOption {
      description = "the entity's handle, as o11n, the org's files and its other entities name it";
      type = lib.types.str;
      readOnly = true;
      default = "${config.class}-${config.name}";
      defaultText = lib.literalExpression ''"''${class}-''${name}"'';
    };
    description = lib.mkOption {
      description = "full name or short purpose description";
      default = "[${config.class}] ${config.name}";
      defaultText = lib.literalExpression ''"[''${class}] ''${name}"'';
      type = lib.types.str;
    };
    grants = lib.mkOption {
      description = "entity groups whose members get to decrypt the entity's secrets";
      default = [ ];
      type = with lib.types; listOf str;
    };
    actors = lib.mkOption {
      description = "the users and root identities that may act as the entity: its identity is encrypted to them and to the root identities";
      default = [ ];
      type = lib.types.listOf (
        lib.types.enum (
          map (name: "user-${name}") (lib.attrNames (context.spec.user or { })) ++ context.org.root-identities
        )
      );
    };
    ids = lib.mkOption {
      description = "entity id in various formats";
      type = lib.types.nullOr context.types.ids.module;
      default = if config.id == null then null else { int = config.id; };
      defaultText = lib.literalMD "`{ int = id; }`, or `null` without an `id`";
    };
    principal = lib.mkOption {
      description = "optional attached principal";
      type = lib.types.nullOr (
        lib.types.submoduleWith {
          modules = [ ./principal.nix ];
          specialArgs = {
            inherit context;
            entity = config;
          };
        }
      );
      default = if config.id == null || config.class == "host" then null else { };
      defaultText = lib.literalMD "`{ }` for an entity with an `id` but a host, or else `null`";
    };
    keys = lib.mkOption {
      description = "the entity's keys, each with its type: its class's, those its configuration adds, and those the org declares for it";
      defaultText = lib.literalMD "the `keys` `org/classes.nix` gives the entity's class; a host's vpn `key` for each of its `vpns`, and its `luks-key` if one of its `disk-layouts` is `encrypted`; a user's `mail` with `mail`; a service's `tls-cert` with a `namespace`, and the keys o11n's modules read of the services they name";
      # Dependency: crates/o11n/src/keys.rs reads each of these types.
      type = lib.types.attrsOf (
        lib.types.enum [
          "age"
          "ssh"
          "wireguard"
          "nix-sign"
          "tls-cert"
          "password"
          "htpasswd"
          "luks"
          "passphrase"
        ]
      );
    };
    publicKeys = lib.mkOption {
      description = "paths to the entity's public keys, one for each of its keys";
      type = lib.types.attrsOf lib.types.path;
      defaultText = lib.literalMD "`<org>/public-keys/<class>-<name>-<key>.<ext>` for each of its `keys`, `<ext>` being `pem` for a tls-cert, `sha512` for a passwd, `htpasswd` for an archive-passwd and `pub` for the rest";
    };
    secrets = lib.mkOption {
      description = "where the entity's secrets are, and the key that decrypts them";
      type = lib.types.submoduleWith {
        modules = [ ./secrets.nix ];
        specialArgs = {
          inherit context;
          entity = config;
        };
      };
    };
    settings = lib.mkOption {
      description = "entity-specific options, passed through as-is to the entity's configuration";
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };
}
