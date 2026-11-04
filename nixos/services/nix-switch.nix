# nixos/services/nix-switch.nix
{
  config,
  lib,
  pkgs,
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
in
{
  services.openssh.extraConfig = ''
    Match User nix-switch
      ForceCommand sudo ${lib.getExe switchSystem} \$SSH_ORIGINAL_COMMAND
  '';

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
