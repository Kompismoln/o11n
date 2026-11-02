{
  lib,
  context,
  entity,
  ...
}:
let
  template =
    class: entity: key:
    let
      exts = {
        tls-cert = "pem";
        default = "pub";
        passwd = "sha512";
        archive-passwd = "htpasswd";
      };
      ext = exts.${key} or exts.default;
    in
    context.path + "/public-keys/${class}-${entity}-${key}.${ext}";
in
{
  options = lib.genAttrs context.classes.${entity.class}.keys (
    key:
    lib.mkOption {
      description = "${key} path for ${entity.class} ${entity.name}";
      type = lib.types.path;
      default = template entity.class entity.name key;
    }
  );
}
