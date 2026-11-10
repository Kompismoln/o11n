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
        # Accommodating for nix, which would otherwise remember a lookup made before the build host had the
        # path as missing for an hour.
        nix-store --realise "$generation" --option narinfo-cache-negative-ttl 0 >/dev/null
        if [[ ! -x $generation/bin/switch-to-configuration ]]; then
          echo "$generation is not a NixOS system" >&2
          exit 1
        fi
        nix-env -p "$profile" --set "$generation"
      elif [[ $generation =~ ^[0-9]+$ ]]; then
        nix-env -p "$profile" --switch-generation "$generation"
      elif [[ $generation == status ]]; then
        # Dependency: crates/o11n/src/status.rs reads these, a line each: <system> <field> <value>.
        for system in booted current next; do
          case $system in
          booted) path=/run/booted-system ;;
          current) path=/run/current-system ;;
          next) path=$profile ;;
          esac
          path=$(readlink -f "$path")
          echo "$system system $path"
          for field in kernel kernel-modules; do
            echo "$system $field $(readlink -f "$path/$field")"
          done
          # Dependency: nixos/org/nix.nix keeps the org and o11n a system is built from under these.
          for input in self:org o11n:o11n; do
            if [[ -e $path/etc/nix/inputs/''${input%%:*} ]]; then
              hash=$(nix-store --query --hash "$(readlink -f "$path/etc/nix/inputs/''${input%%:*}")")
              echo "$system ''${input#*:} $(nix hash to-sri "$hash" 2>/dev/null)"
            fi
          done
        done
        exit 0
      elif [[ $generation == allotments ]]; then
        # Dependency: nixos/allotment-sync.nix puts this on a host that syncs an allotment, which a host that doesn't, or
        # runs a system from before, says nothing for.
        if [[ -x /run/current-system/sw/bin/allotment-sync-status ]]; then
          exec /run/current-system/sw/bin/allotment-sync-status
        fi
        exit 0
      elif [[ $generation == databases ]]; then
        # Dependency: nixos/postgresql.nix puts this on a host with a database, which a host without, or runs a system
        # from before, says nothing for.
        if [[ -x /run/current-system/sw/bin/postgresql-collation-status ]]; then
          exec /run/current-system/sw/bin/postgresql-collation-status
        fi
        exit 0
      elif [[ $generation == nextcloud ]]; then
        # Dependency: nixos/apps/nextcloud.nix puts one of these on a host for each nextcloud with a home or an external
        # storage, which a host without, or runs a system from before, says nothing for.
        for status in /run/current-system/sw/bin/nextcloud-status-*; do
          if [[ -x $status ]]; then
            "$status"
          fi
        done
        exit 0
      elif [[ -n $generation ]]; then
        echo "usage: switch-system [store path | generation | status | allotments | databases | nextcloud]" >&2
        exit 1
      fi

      nix-env -p "$profile" --list-generations

      if [[ -n $generation ]]; then
        "$profile/bin/switch-to-configuration" switch
        # Fact: switch installs the boot loader, which copies the initrd's secrets, before the activation that has
        # sops-nix write them, so the initrd would hold those of the deployment before.
        "$profile/bin/switch-to-configuration" boot
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
