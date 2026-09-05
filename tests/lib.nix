# tests/lib.nix
{ pkgs }:
{
  evalNixosModule =
    modules:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit pkgs;
      inherit (pkgs) lib;
      system = pkgs.stdenv.hostPlatform.system;
      inherit modules;
    }).config;
}
