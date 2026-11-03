{
  lib,
  config,
  context,
  ...
}:
let
  relative =
    path:
    builtins.unsafeDiscardStringContext (lib.removePrefix "${toString context.path}/" (toString path));

  stateful =
    entity: entity.principal != null && entity.id != null && entity.principal.home != "/var/empty";

  exported =
    entity:
    {
      inherit (entity)
        class
        name
        grants
        actors
        settings
        keys
        ;
      publicKeys = lib.mapAttrs (_: relative) entity.publicKeys;
      secrets = {
        sopsFile = relative entity.secrets.sopsFile;
        identityFile = relative entity.secrets.identityFile;
        inherit (entity.secrets) decryptionKey;
      };
    }
    // lib.optionalAttrs (stateful entity) {
      state = {
        inherit (entity.principal) home;
        hosts = map (host: host.name) (
          lib.filter (host: lib.any (principal: principal.handle == entity.handle) host.principals) (
            lib.attrValues config.host
          )
        );
      };
    }
    // lib.optionalAttrs (entity.class == "host") {
      inherit (entity)
        endpoint
        roles
        vpns
        system
        luksKeyFile
        ;
    };

  root = name: {
    class = "root";
    inherit name;
    grants = [ ];
    actors = [ ];
    settings = { };
    inherit (context.classes.root) keys;
    publicKeys.age-key = "public-keys/root-${name}-age-key.pub";
    secrets.identityFile = "keys/root-${name}";
  };
in
{
  options.export = lib.mkOption {
    description = "the org as plain data, for the tools that act on it";
    internal = true;
    readOnly = true;
    type = lib.types.raw;
    default = {
      inherit (config)
        name
        endpoint
        namespaces
        build-hosts
        root-identities
        ops
        ;
      inherit (context) classes;
      entities =
        lib.genAttrs' (lib.unique (
          map (lib.removePrefix "root-") config.root-identities ++ lib.attrNames config.root
        )) (name: lib.nameValuePair "root-${name}" (root name))
        // lib.mapAttrs (_: exported) config.entities;
    };
  };
}
