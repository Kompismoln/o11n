# nixos/services/nix-build.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  daemon = "${config.nix.package}/bin/nix-daemon --stdio";

  # Fact: the operator sends the flake first, inputs and all (nix flake archive).
  buildSystem = pkgs.writeShellApplication {
    name = "build-system";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
    ];
    text = ''
      usage() {
        echo "usage: build-system <flake store path> <host>" >&2
        exit 1
      }

      [[ $# -eq 2 ]] || usage
      flake=$1 host=$2
      [[ $flake =~ ^${builtins.storeDir}/[0-9a-z]{32}-[0-9A-Za-z+._-]+$ && $host =~ ^[0-9A-Za-z_-]+$ ]] ||
        usage
      nix-store --check-validity "$flake"

      # Accommodating for nix-build, which has no home of its own for nix's caches.
      HOME=$(mktemp -d)
      export HOME
      trap 'rm -rf "$HOME"' EXIT

      nix build --no-link --print-out-paths --option accept-flake-config false \
        "path:$flake#nixosConfigurations.$host.config.system.build.toplevel"
    '';
  };

  nixBuildCommand =
    if lib.elem host.name org.build-hosts then
      pkgs.writeShellScript "nix-build-command" ''
        read -ra args <<<"''${SSH_ORIGINAL_COMMAND:-}"
        if [[ ''${args[0]:-} == build-system ]]; then
          exec ${lib.getExe buildSystem} "''${args[@]:1}"
        fi
        exec ${daemon}
      ''
    else
      daemon;
in
{
  services.openssh.extraConfig = ''
    Match User nix-build
      ForceCommand ${nixBuildCommand}
  '';
}
