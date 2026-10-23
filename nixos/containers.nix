# nixos/containers.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.o11n) preserve;

  containersRoot = preserve.onStorage "/var/lib/${lib.optionalString (lib.versionAtLeast config.system.stateVersion "22.05") "nixos-"}containers";
  snapshotSuffix = lib.concatStrings (lib.replicate 16 "[0-9a-f]");

  # nspawn runs an ephemeral container in a snapshot next to its root and removes it when the
  # container stops, but it can't once the container has made /var/empty immutable, as NixOS
  # does: the snapshot and its lock stay behind.
  removeSnapshots = name: ''
    for snapshot in ${containersRoot}/.#snapshot.${name}${snapshotSuffix}; do
      [ -e "$snapshot" ] || continue
      if [ -e "$snapshot/var/empty" ]; then
        chattr -i "$snapshot/var/empty"
      fi
      rm -rf -- "$snapshot"
    done
    rm -f -- ${containersRoot}/.#.#snapshot.${name}${snapshotSuffix}.lck
  '';
in
{
  imports = [
    ./preserve-paths.nix
  ];

  config = lib.mkIf preserve.enable {
    systemd.tmpfiles.rules = lib.optional (
      config.containers != { }
    ) "d ${containersRoot} 0700 root root - -";

    # Upstream keeps container roots on /var, and an ephemeral one's on /run.
    systemd.services = lib.mapAttrs' (
      name: container:
      lib.nameValuePair "container@${name}" {
        environment.root = lib.mkForce "${containersRoot}/%i";
        unitConfig.RequiresMountsFor = [ "${containersRoot}/%i" ];
        path = lib.mkIf container.ephemeral [ pkgs.e2fsprogs ];
        # After every stop, and before a start in case the host went down with the container.
        preStart = lib.mkIf container.ephemeral (lib.mkBefore (removeSnapshots name));
        postStop = lib.mkIf container.ephemeral (removeSnapshots name);
      }
    ) config.containers;
  };
}
