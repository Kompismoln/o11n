# nixos/nix.nix
{
  config,
  host,
  inputs,
  o11nInputs,
  lib,
  pkgs,
  org,
  ...
}:

let

  switchSystem = pkgs.writeShellApplication {
    name = "switch-system";
    runtimeInputs = [ config.nix.package ];
    text = ''
      profile=/nix/var/nix/profiles/system
      generation=''${1:-}

      if [[ $generation == ${builtins.storeDir}/* ]]; then
        # A lookup made before the build host had the path would otherwise be remembered as
        # missing for an hour.
        nix-store --realise "$generation" --option narinfo-cache-negative-ttl 0 >/dev/null
        if [[ ! -x $generation/bin/switch-to-configuration ]]; then
          echo "$generation is not a NixOS system" >&2
          exit 1
        fi
        nix-env -p "$profile" --set "$generation"
      elif [[ $generation =~ ^[0-9]+$ ]]; then
        nix-env -p "$profile" --switch-generation "$generation"
      elif [[ -n $generation ]]; then
        echo "usage: switch-system [store path | generation]" >&2
        exit 1
      fi

      nix-env -p "$profile" --list-generations

      if [[ -n $generation ]]; then
        "$profile/bin/switch-to-configuration" switch
      fi
    '';
  };

  substituters = lib.filter (
    peer: peer.name != host.name && lib.elem "substituter" peer.roles && host.reach.${peer.name} != null
  ) (lib.attrValues org.host);
in
{
  assertions = map (buildHost: {
    assertion = lib.elem "substituter" org.host.${buildHost}.roles;
    message = "Build host ${buildHost} needs the substituter role, or no host can fetch what it builds.";
  }) org.build-hosts;

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
      download-attempts = 3;
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
      ]
      # After cache.nixos.org (40), so that public paths don't come over a vpn.
      ++ map (peer: "http://${host.reach.${peer.name}.fqdn}:5000?priority=50") substituters;
      connect-timeout = 5;
      fallback = true;
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
        ForceCommand ${config.nix.package}/bin/nix-daemon --stdio

      Match User nix-switch
        ForceCommand sudo ${lib.getExe switchSystem} \$SSH_ORIGINAL_COMMAND

      Match User nix-push
        ForceCommand ${pkgs.nix}/bin/nix-store --serve --write
    '';
  };

  security.sudo.extraRules = [
    {
      users = [ "nix-switch" ];
      commands = [
        {
          command = lib.getExe switchSystem;
          options = [ "NOPASSWD" ];
        }
        {
          command = "${lib.getExe switchSystem} *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

}
