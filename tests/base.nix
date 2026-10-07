# tests/base.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;
  outputs = o11nLib.fromPath ./inventories/base;
in
lib.runTests {
  test_org_base = {
    expr = outputs.org.endpoint;
    expected = "example.com";
  };
  test_disko_base = {
    expr = outputs.diskoConfigurations;
    expected = { };
  };
  test_home_base = {
    expr = outputs.homeConfigurations;
    expected = { };
  };
  test_nixos_base = {
    expr = outputs.nixosConfigurations;
    expected = { };
  };
}
