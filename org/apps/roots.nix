{
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  # Policy: a drive's root can be an entity's home, which the host mounts as the app's user's; a photos app's is a
  # share alone.
  homed = config.kind == "drive";

  # Dependency: org/types.nix gives these kinds this module.
  rooted = [
    "drive"
    "photos"
  ];

  # Policy: no two roots are one directory, which two apps, or two users, would each take as theirs; read from the
  # org's spec, as each app's roots would otherwise read every other's, its own among them.
  places = lib.concatLists (
    lib.mapAttrsToList (
      name: app:
      lib.optionals (lib.elem (app.kind or null) rooted) (
        lib.mapAttrsToList (user: root: {
          at = "app.${name}.roots.${user}";
          place = "${root.entity or root}/${root.path or app.kind}";
        }) (app.roots or { })
      )
    ) (context.spec.app or { })
  );
  shared = lib.filterAttrs (_: same: lib.length same > 1) (lib.groupBy (root: root.place) places);

  root = {
    options = {
      entity = lib.mkOption {
        description = "the entity, by its handle, the root is in: a store with an `smb` share, or, for a drive, a principal whose home is on the app's hosts";
        type = lib.types.str;
      };
      path = lib.mkOption {
        description = "the directory in the share or the home that is the root, which has to be there";
        type = lib.types.str;
        default = config.kind;
        defaultText = lib.literalExpression "kind";
      };
    };
  };

  resolved = lib.mapAttrs (
    user: root:
    let
      at = "app.${config.name}.roots.${user}";
      entity = org.entities.${root.entity} or (throw "${at}: ${root.entity} is no entity of the org's.");
      home = (entity.principal or null).home or "/var/empty";
      clash = lib.findFirst (same: lib.any (other: other.at == at) same) null (lib.attrValues shared);
    in
    if clash != null then
      throw "${at}: ${
        lib.concatMapStringsSep " and " (other: other.at) clash
      } are each ${(lib.head clash).place}: set a path for each but one."
    else if entity.smb or null != null then
      {
        inherit user;
        smb = {
          inherit (entity.smb) host login;
          share = "${entity.smb.share}/${root.path}";
          key = {
            inherit (entity) handle;
            secret = {
              name = "${entity.name}/smb-password";
              inherit (entity.secrets) sopsFile;
            };
          };
        };
      }
    else if homed && home != "/var/empty" then
      {
        inherit user;
        home = {
          path = "${home}/${root.path}";
          owner = entity.name;
        };
      }
    else
      throw "${at}: ${root.entity} is no store with an smb share${lib.optionalString homed ", nor a principal with a home"}: set its smb${lib.optionalString homed ", or its principal.hasHome"}."
  ) config.roots;
in
{
  options = {
    roots = lib.mkOption {
      description = "each user's root, by user: where the app keeps the user's data in its own layout, a directory, `path`, of the store or the home that `entity` names, or just that entity";
      type = lib.types.attrsOf (
        lib.types.coercedTo lib.types.str (entity: { inherit entity; }) (lib.types.submodule root)
      );
      default = { };
      example = lib.literalExpression ''
        {
          alice = "store-alice";
          bob = { entity = "store-bob"; path = "drive-old"; };
        }
      '';
    };
    shares = lib.mkOption {
      description = "each root of a store's smb share, with its user, the share and path, and the key it logs in with";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map (root: { inherit (root) user; } // root.smb) (
        lib.filter (root: root ? smb) (lib.attrValues resolved)
      );
      defaultText = lib.literalMD "each of `roots` in a store with an `smb`, at its `path` in the share";
    };
    homes = lib.mkOption {
      description = "each root of an entity's home, with its user, the directory and its owner";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map (root: { inherit (root) user; } // root.home) (
        lib.filter (root: root ? home) (lib.attrValues resolved)
      );
      defaultText = lib.literalMD "each of `roots` in a principal's home, at its `path` there";
    };
  };
}
