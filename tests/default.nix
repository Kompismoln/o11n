{
  pkgs,
  o11nLib,
  o11n,
}:
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
      name = "eval-nixos-${lib.removeSuffix ".nix" file}";
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
      name = "eval-inventory-${inventory}";
    in
    lib.nameValuePair name (
      mkCheck name (callTests ./inventories/${inventory}/tests.nix (args // { inherit outputs; }))
    )
  ) inventories;

  homeChecks.eval-homes = pkgs.runCommand "eval-homes" {
    drvs = lib.concatMap (
      outputs:
      map (home: builtins.unsafeDiscardOutputDependency home.activationPackage.drvPath) (
        lib.attrValues outputs.homeConfigurations
      )
    ) (lib.attrValues inventories);
  } "touch $out";

  # Policy: o11n reads the sample as an org's clone, and its answers are checked against the keys on disk.
  o11nChecks.eval-o11n-sample =
    pkgs.runCommand "eval-o11n-sample"
      {
        nativeBuildInputs = [ o11n ];
        export = builtins.toFile "export.json" (builtins.toJSON inventories.sample.org.export);
        org = ./inventories/sample;
      }
      ''
        export O11N_EXPORT=$export O11N_ORG_ROOT=$org
        [[ $(o11n recipients service-nix-remote | tr '\n' ' ') == "host-gw root-1 service-nix-remote " ]]
        [[ $(o11n entities 'host:remote-builder+server' 'user-*' | tr '\n' ' ') == "host-gw user-admin " ]]
        [[ $(o11n resolve tunnel) == service-reverse-tunnel ]]
        [[ $(o11n get build-hosts) == gw ]]
        [[ $(o11n ops check | tr '\n' ' ') == "host-gw check:age-key service-rescue verify:ssh-key service-rescue verify:passwd " ]]
        [[ -f $org/$(o11n public-key host-gw ssh-key) && -f $org/$(o11n secrets user-admin) ]]
        diff <(o11n sops-yaml service-nix-remote) - <<EOF
        creation_rules:
          - path_regex: enc/service-nix-remote.yaml
            key_groups:
              - age:
                - $(cat $org/public-keys/host-gw-age-key.pub)
                - $(cat $org/public-keys/root-1-age-key.pub)
                - $(cat $org/public-keys/service-nix-remote-age-key.pub)
        EOF
        ! o11n entities user-nobody
        touch $out
      '';

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
        name = "leaks-${inventory}-${host}";
      in
      lib.nameValuePair name (
        pkgs.runCommand name
          {
            drv = builtins.unsafeDiscardOutputDependency nixos.config.system.build.toplevel.drvPath;
          }
          ''
            bash ${./leaks.sh} ${builtins.storeDir} "$drv" ${lib.escapeShellArgs leakPatterns} > $out
          ''
      )
    ) outputs.nixosConfigurations
  ) inventories;

  # Policy: a stick goes where it's needed and can be lost there, so nothing of the inventory's
  # may be on it but the public keys it reads.
  rescueUsb = evalNixosModule [
    ../nixos/org/rescue-usb.nix
    {
      _module.args.org = inventories.sample.org;
      o11n.rescue-usb.via = "gw";
    }
  ];

  rescueUsbChecks.leaks-sample-rescue-usb =
    pkgs.runCommand "leaks-sample-rescue-usb"
      {
        drv = builtins.unsafeDiscardOutputDependency rescueUsb.system.build.images.iso-installer.drvPath;
      }
      ''
        bash ${./leaks.sh} ${builtins.storeDir} "$drv" AGE-SECRET-KEY 'ENC\[AES256_GCM' > $out
      '';
in
{
  eval = nixosChecks // inventoryChecks // homeChecks // o11nChecks;
  leaks = hostChecks // rescueUsbChecks;
}
// lib.mapAttrs (name: check: { ${name} = check; }) (import ./source.nix { inherit pkgs; })
