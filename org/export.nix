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

  entities = lib.concatMap lib.attrValues [
    config.host
    config.user
    config.service
    config.app
    config.store
  ];

  exported =
    entity:
    {
      inherit (entity) class name grants;
      publicKeys = lib.mapAttrs (_: relative) entity.publicKeys;
      secrets = {
        sopsFile = relative entity.secrets.sopsFile;
        inherit (entity.secrets) decryptionKey;
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
    publicKeys.age-key = "public-keys/root-${name}-age-key.pub";
    secrets.ageKeyFile = "keys/root-${name}";
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
        lib.mapAttrs' (name: _: lib.nameValuePair "root-${name}" (root name)) config.root
        // lib.listToAttrs (
          map (entity: lib.nameValuePair "${entity.class}-${entity.name}" (exported entity)) entities
        );
    };
  };
}
