# nixos/nix.nix
{
  inputs,
  o11nInputs,
  lib,
  pkgs,
  org,
  ...
}:

let

  nixservicePkg =
    pkgs.runCommand "nixservice"
      {
        buildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin
        cp ${../../tools/remote/nixservice.sh} $out/bin/nixservice-unwrapped
        chmod +x $out/bin/nixservice-unwrapped

        makeWrapper $out/bin/nixservice-unwrapped $out/bin/nixservice \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.lix
              pkgs.git
            ]
          } \
          --set REPO "${with org.flake; "${type}:${owner}/${repo}"}" \
          --set BUILD_HOST "http://stationary.km:5000"
      '';
in
{
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKeyFile = ../../public-keys/github-ssh-key.pub;
  };

  nix = {
    package = lib.mkDefault pkgs.lix;
    registry = {
      self.flake = inputs.self;
      o11n = {
        from = {
          id = "o11n";
          type = "indirect";
        };
        to = org.flake;
      };
      nixpkgs.flake = o11nInputs.nixpkgs;
    };
    channel.enable = false;
    settings = {
      auto-optimise-store = false;
      bash-prompt-prefix = "(nix:$name)\\040";
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      max-jobs = "auto";
      nix-path = lib.mkForce "nixpkgs=/etc/nix/inputs/nixpkgs";
      substituters = [
        "https://cache.nixos.org"
        "https://cache.lix.systems"
      ];
      trusted-users = [
        "@wheel"
        "nix-push"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.lix.systems:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
        (builtins.readFile org.service.nix-serve.publicKeys.nix-sign)
      ];
      use-xdg-base-directories = true;
    };
  };

  environment.etc = {
    "nix/inputs/self".source = "${inputs.self}";
    "nix/inputs/nixpkgs".source = "${o11nInputs.nixpkgs}";
  };

  services.openssh = {
    extraConfig = ''
      Match User nix-build
        ForceCommand ${nixservicePkg}/bin/nixservice \$SSH_ORIGINAL_COMMAND

      Match User nix-switch
        ForceCommand sudo ${nixservicePkg}/bin/nixservice switch \$SSH_ORIGINAL_COMMAND

      Match User nix-push
        ForceCommand ${pkgs.nix}/bin/nix-store --serve --write
    '';
  };

  security.sudo.extraRules = [
    {
      users = [ "nix-switch" ];
      commands = [
        {
          command = "${nixservicePkg}/bin/nixservice switch";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${nixservicePkg}/bin/nixservice switch *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

}
