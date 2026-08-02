{ pkgs, o11nLib }:
let
  mkTest =
    name: tests:
    let
      inherit (pkgs) lib;
      inherit tests;
      testResults = lib.concatMap (test: import test { inherit pkgs o11nLib; }) tests;
    in
    if testResults == [ ] then
      pkgs.emptyFile
    else
      pkgs.runCommand name
        {
          buildInputs = [ pkgs.jq ];
          results = builtins.toJSON testResults;
        }
        ''
          echo "$results" | jq -M .
          exit 1
        '';
in
{
  test-kompismoln-spec =
    let
      tests = [
        ./kompismoln-spec.nix
      ];
    in
    mkTest "test-kompismoln-spec" tests;

  test-base-spec =
    let
      tests = [
        ./base-spec.nix
      ];
    in
    mkTest "test-base-spec" tests;
}
