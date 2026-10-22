# roles/remote-builder-relay.nix
{
  flake.nixosModules.remote-builder-relay = {
    imports = [
      ../nixos/org/remote-builder-relay.nix
    ];
  };
}
