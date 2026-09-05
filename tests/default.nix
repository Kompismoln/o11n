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
          echo "$results" | jq .
          exit 1
        '';
in
{
  test-kompismoln =
    let
      tests = [
        ./kompismoln.nix
      ];
    in
    mkTest "test-kompismoln" tests;

  test-base =
    let
      tests = [
        ./base.nix
      ];
    in
    mkTest "test-base" tests;

  test-keycloak =
    let
      tests = [
        ./keycloak.nix
      ];
    in
    mkTest "test-keycloak" tests;
}
