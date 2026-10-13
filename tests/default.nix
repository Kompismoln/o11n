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
    inventory: o11nLib.fromInventory { path = ./inventories/${inventory}; }
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

  # Names from the org o11n was first written for. No host of any inventory should carry them.
  leakPatterns = [
    "kompismoln"
    "ahbk"
    "helsinki"
    "stationary"
    "pelle"
    "malborg"
    "\\.km[0-9]*"
  ];

  # Every NixOS host in an inventory evaluates, and nothing it is built from mentions
  # the org o11n was first written for: check inventory-<inventory>-<host>.
  # The check reads the host's derivations without building them.
  hostChecks = lib.concatMapAttrs (
    inventory: outputs:
    lib.mapAttrs' (
      host: nixos:
      let
        name = "inventory-${inventory}-${host}";
      in
      lib.nameValuePair name (
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pkgs.python3 ];
            drv = builtins.unsafeDiscardOutputDependency nixos.config.system.build.toplevel.drvPath;
          }
          ''
            python3 ${./leaks.py} ${builtins.storeDir} "$drv" ${lib.escapeShellArgs leakPatterns} > $out
          ''
      )
    ) outputs.nixosConfigurations
  ) inventories;
in
nixosChecks // inventoryChecks // hostChecks
