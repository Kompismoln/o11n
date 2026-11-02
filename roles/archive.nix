# roles/archive.nix
{
  flake.nixosModules.archive = {
    imports = [
      ../nixos/org/sops.nix
      ../nixos/org/archive.nix
    ];
  };
}
