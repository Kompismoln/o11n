{ pkgs, o11nLib }:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) callTests mkCheck evalNixosModule;

  args = {
    inherit pkgs lib evalNixosModule;
  };

  entries = dir: type: lib.attrNames (lib.filterAttrs (_: t: t == type) (builtins.readDir dir));

  nixosChecks = lib.genAttrs' (lib.filter (lib.hasSuffix ".nix") (entries ./nixos "regular")) (
    file:
    let
      name = "nixos-${lib.removeSuffix ".nix" file}";
    in
    lib.nameValuePair name (mkCheck name (callTests ./nixos/${file} args))
  );

  inventories = lib.genAttrs (entries ./inventories "directory") (
    inventory:
    let
      path = ./inventories/${inventory};
    in
    o11nLib.fromInventory {
      inherit path;
      inputs = lib.optionalAttrs (builtins.pathExists (path + "/inputs.nix")) (
        import (path + "/inputs.nix")
      );
    }
  );

  inventoryChecks = lib.mapAttrs' (
    inventory: outputs:
    let
      name = "inventory-${inventory}";
    in
    lib.nameValuePair name (
      mkCheck name (callTests ./inventories/${inventory}/tests.nix (args // { inherit outputs; }))
    )
  ) inventories;

  leakPatterns = [
    "kompismoln"
    "ahbk"
    "helsinki"
    "stationary"
    "pelle"
    "malborg"
    "\\.km[0-9]*"
  ];

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

  # A stick goes where it's needed and can be lost there: nothing of the inventory's may be on
  # it but the public keys it reads.
  rescueUsb = evalNixosModule [
    ../nixos/org/rescue-usb.nix
    {
      _module.args.org = inventories.sample.org;
      o11n.rescue-usb.via = "gw";
    }
  ];

  rescueUsbChecks.inventory-sample-rescue-usb =
    pkgs.runCommand "inventory-sample-rescue-usb"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        drv = builtins.unsafeDiscardOutputDependency rescueUsb.system.build.images.iso-installer.drvPath;
      }
      ''
        python3 ${./leaks.py} ${builtins.storeDir} "$drv" AGE-SECRET-KEY 'ENC\[AES256_GCM' > $out
      '';
in
nixosChecks // inventoryChecks // hostChecks // rescueUsbChecks
