# tests/base.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;
  outputs = o11nLib.fromPath ./inventories/principals;
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
  test_nixos_huggingface_name = {
    expr = outputs.nixosConfigurations.test-host.config.users.users.huggingface.name;
    expected = "huggingface";
  };
  test_nixos_sftps = {
    expr = outputs.nixosConfigurations.test-host.config.services.openssh.extraConfig;
    expected = ''
      Match User test-app
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
        AllowAgentForwarding no
        PermitTunnel no

      Match User huggingface
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
        AllowAgentForwarding no
        PermitTunnel no
    '';
  };
}
