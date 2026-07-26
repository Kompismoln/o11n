# tests/kompismoln.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;

  flake = builtins.getFlake (toString /home/alex/Desktop/org);

  outputs = o11nLib.fromFlake flake;

  diskoCfgs = outputs.diskoConfigurations;
  homeCfgs = outputs.homeConfigurations;
  nixosCfgs = outputs.nixosConfigurations;
in
lib.runTests {
  test_context_flake = {
    expr = outputs.context.flake;
    expected = "kompismoln.se";
  };
  test_endpoint = {
    expr = outputs.org.endpoint;
    expected = "kompismoln.se";
  };
  test_disko = {
    expr = lib.attrNames diskoCfgs;
    expected = [
      "adele-main"
      "helsinki-main"
      "laptop-main"
      "pelle-main"
      "stationary-main"
      "stationary-single-xfs"
      "stationary-tungsten"
    ];
  };
  test_home_kompismoln = {
    expr = lib.attrNames homeCfgs;
    expected = [
      "alex@laptop"
      "alex@lenovo"
      "alex@pelle"
      "ami@adele"
    ];
  };
  test_nixos_kompismoln = {
    expr = lib.attrNames nixosCfgs;
    expected = [
      "adele"
      "bootstrap"
      "friday"
      "helsinki"
      "laptop"
      "lenovo"
      "pelle"
      "stationary"
    ];
  };
  test_chatddx = {
    expr = builtins.pathExists nixosCfgs.stationary.config.o11n.django.apps.chatddx-dev.package.outPath;
    expected = true;
  };
  test_vim_highlights = {
    expr =
      homeCfgs."alex@lenovo".config.programs.nixvim.colorschemes.cyberdream.settings.highlights.Normal.bg;
    expected = "#0a0a0a";
  };
  test_nix_self_path = {
    expr = builtins.pathExists nixosCfgs.lenovo.config.nix.registry.self.flake.outPath;
    expected = true;
  };
  test_pelle_wifi = {
    expr = nixosCfgs.pelle.config.systemd.network.networks."10-wlp4s0".dhcpV4Config.RouteMetric;
    expected = 2048;
  };
  test_helsinki_mailserver = {
    expr = nixosCfgs.helsinki.config.o11n.mailserver.endpoint;
    expected = "kompismoln.se";
  };
  test_helsinki_mailserver_relay_domains = {
    expr = nixosCfgs.helsinki.config.o11n.mailserver.relayDomains;
    expected = [
      "esse.nu"
      "klimatkalendern.nu"
    ];
  };
  test_helsinki_mailserver_mailboxes = {
    expr = nixosCfgs.helsinki.config.o11n.mailserver.mailboxDomains;
    expected = [
      "ahbk.se"
      "chatddx.com"
      "kompismoln.se"
      "sverigesval.org"
    ];
  };
  test_pelle_nix_build_uid = {
    expr = nixosCfgs.pelle.config.users.users.nix-build.uid;
    expected = 2002;
  };
  test_nix_build_ssh_key = {
    expr = builtins.pathExists outputs.org.service.nix-build.publicKeys.ssh-key;
    expected = true;
  };
  test_vpn_key = {
    expr = nixosCfgs.helsinki.config.systemd.network.netdevs."20-wg1".wireguardConfig.PrivateKeyFile;
    expected = "/run/secrets/wg1-key";
  };
  test_rescue = {
    expr = builtins.pathExists outputs.org.service.rescue.publicKeys.passwd;
    expected = true;
  };
  test_locksmith_passwd = {
    expr = nixosCfgs.lenovo.config.users.users.locksmith.hashedPasswordFile;
    expected = null;
  };
  test_locksmith_sops = {
    expr = nixosCfgs.lenovo.config.sops.secrets."locksmith/passwd-sha512" or null;
    expected = null;
  };
  test_vpn_fqdn = {
    expr = outputs.org.host.lenovo.network."wg1".fqdn;
    expected = "lenovo.km1";
  };
}
