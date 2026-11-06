{ lib, ... }:
{
  options = {
    realms = lib.mkOption {
      description = "the realms whose settings o11n keeps, by name; Keycloak keeps the rest of a realm, its users included";
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options.displayName = lib.mkOption {
              description = "the realm's name as its pages and mail show it";
              type = lib.types.str;
              default = name;
              defaultText = lib.literalMD "the realm's name";
            };
          }
        )
      );
    };
  };
}
