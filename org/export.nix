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
  roots = map (name: "root-${name}") (lib.attrNames config.root);
  ids = roots ++ map (entity: "${entity.class}-${entity.name}") entities;
  byId = lib.listToAttrs (
    map (entity: lib.nameValuePair "${entity.class}-${entity.name}" entity) entities
  );

  ofClass = class: lib.filter (id: lib.hasPrefix "${class}-" id) ids;
  members =
    group:
    let
      byRoles = lib.splitString ":" group;
      byClass = lib.splitString "-" group;
      class = lib.head byRoles;
      roles = lib.splitString "+" (lib.last byRoles);
      classes = if class == "*" then lib.attrNames context.classes else [ class ];
    in
    if group == "*" then
      ids
    else if lib.length byRoles == 2 then
      lib.filter (id: lib.all (role: lib.elem role (byId.${id}.roles or [ ])) roles) (
        lib.concatMap ofClass classes
      )
    else if lib.length byClass >= 2 && lib.last byClass == "*" then
      ofClass (lib.head byClass)
    else if lib.length byClass >= 2 then
      [ group ]
    else
      throw "org: `${group}` is no entity group: *, <class>-*, <class>:<role>[+<role>]... or <class>-<name>";

  exported = entity: {
    inherit (entity) class name grants;
    recipients = lib.unique (
      lib.sort lib.lessThan (
        [ "${entity.class}-${entity.name}" ]
        ++ config.root-identities
        ++ lib.concatMap members entity.grants
      )
    );
    publicKeys = lib.mapAttrs (_: relative) entity.publicKeys;
    secrets = {
      sopsFile = relative entity.secrets.sopsFile;
      inherit (entity.secrets) decryptionKey;
    };
  };

  exportedHost = host: {
    inherit (host)
      endpoint
      roles
      vpns
      system
      luksKeyFile
      ;
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
        ;
      inherit (context) classes;
      entities =
        lib.genAttrs roots (id: {
          class = "root";
          name = lib.removePrefix "root-" id;
          publicKeys.age-key = "public-keys/${id}-age-key.pub";
          secrets.ageKeyFile = "keys/${id}";
        })
        // lib.mapAttrs (
          _: entity: exported entity // lib.optionalAttrs (entity.class == "host") (exportedHost entity)
        ) byId;
      ops = lib.mapAttrs (
        _: groups:
        lib.concatLists (
          lib.mapAttrsToList (
            group: ops:
            lib.concatMap (
              id:
              map (op: {
                entity = id;
                inherit op;
              }) ops
            ) (members group)
          ) groups
        )
      ) config.ops;
    };
  };
}
