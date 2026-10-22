# roles/remote-builder.nix
{
  flake.nixosModules.remote-builder = {
    imports = [
      ../nixos/org/remote-builder.nix
    ];
  };
}
