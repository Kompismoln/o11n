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

  # The configurations made from each tests/inventories/<inventory>.
  inventories = lib.genAttrs (entries ./inventories "directory") (
    inventory: o11nLib.fromPath ./inventories/${inventory}
  );

  # tests/inventories/<inventory>/tests.nix tests the configurations made from that inventory: check inventory-<inventory>.
  inventoryChecks = lib.mapAttrs' (
    inventory: outputs:
    let
      name = "inventory-${inventory}";
    in
    lib.nameValuePair name (
      mkCheck name (callTests ./inventories/${inventory}/tests.nix (args // { inherit outputs; }))
    )
  ) inventories;

  # Every NixOS host in an inventory evaluates: check inventory-<inventory>-<host>.
  # The check holds the path of the host's system derivation, without building it.
  hostChecks = lib.concatMapAttrs (
    inventory: outputs:
    lib.mapAttrs' (
      host: nixos:
      let
        name = "inventory-${inventory}-${host}";
      in
      lib.nameValuePair name (
        pkgs.writeText name (builtins.unsafeDiscardStringContext nixos.config.system.build.toplevel.drvPath)
      )
    ) outputs.nixosConfigurations
  ) inventories;
in
nixosChecks // inventoryChecks // hostChecks
