{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  callTests =
    file: args:
    let
      tests = import file;
    in
    tests (builtins.intersectAttrs (lib.functionArgs tests) args);

  mkCheck =
    name: tests:
    let
      failures = lib.runTests tests;
    in
    if failures == [ ] then
      pkgs.emptyFile
    else
      pkgs.runCommand name
        {
          nativeBuildInputs = [ pkgs.jq ];
          failures = builtins.toJSON failures;
        }
        ''
          echo "$failures" | jq .
          exit 1
        '';

  evalNixosModule =
    modules:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit pkgs;
      inherit (pkgs) lib;
      system = pkgs.stdenv.hostPlatform.system;
      inherit modules;
    }).config;
}
