# org/inventory.nix
{
  context,
  lib,
  ...
}:
{
  options = lib.genAttrs (lib.attrNames context.classes) (
    class:
    lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          imports = [ ./${class}.nix ];
          _module.args.context = context;
        }
      );
      default = { };
    }
  );
}
