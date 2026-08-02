# org/spec-v1/mkInventory.nix
{ context, lib, ... }:
let
  classes = lib.attrNames context.classes;
in
{
  org.${context.spec-v1.name} = lib.filterAttrs (name: _: !(lib.elem name classes)) context.spec-v1;
}
