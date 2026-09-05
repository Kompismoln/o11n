# tests/lib.nix
#
# Small helpers shared between test files.
{ pkgs }:
{
  # Evaluate a bare NixOS configuration (the full module set from
  # `pkgs.path`, plus `modules`) and return its `.config`. Useful for
  # testing a single nixos/*.nix module in isolation, without needing a
  # full host/org definition. Doesn't build anything (no
  # `config.system.build.toplevel` access), so mandatory options like
  # `fileSystems."/"` don't need to be set.
  evalNixosModule =
    modules:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit pkgs;
      inherit (pkgs) lib;
      system = pkgs.stdenv.hostPlatform.system;
      inherit modules;
    }).config;
}
