# tests/default.nix
{ pkgs, o11nLib }:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) callTests mkCheck evalNixosModule;

  args = {
    inherit pkgs lib evalNixosModule;
  };

  entries = dir: type: lib.attrNames (lib.filterAttrs (_: t: t == type) (builtins.readDir dir));

  # tests/nixos/<module>.nix tests nixos/<module>.nix on its own: check nixos-<module>.
  nixosChecks = lib.genAttrs' (lib.filter (lib.hasSuffix ".nix") (entries ./nixos "regular")) (
    file:
    let
      name = "nixos-${lib.removeSuffix ".nix" file}";
    in
    lib.nameValuePair name (mkCheck name (callTests ./nixos/${file} args))
  );

  # tests/inventories/<inventory>/tests.nix tests the configurations made from that inventory: check inventory-<inventory>.
  inventoryChecks = lib.genAttrs' (entries ./inventories "directory") (
    inventory:
    let
      name = "inventory-${inventory}";
    in
    lib.nameValuePair name (
      mkCheck name (
        callTests ./inventories/${inventory}/tests.nix (
          args
          // {
            outputs = o11nLib.fromPath ./inventories/${inventory};
          }
        )
      )
    )
  );
in
nixosChecks // inventoryChecks
