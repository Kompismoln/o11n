# nixos/org/state.nix
{
  config,
  host,
  lib,
  ...
}:
let
  # Duplication: as nixos/org/principals.nix orders a host's principals, by class, then name.
  stateful =
    lib.concatMap
      (
        class:
        lib.sortOn (entity: entity.name) (
          lib.filter (entity: entity.class == class && entity.principal.state != null) host.principals
        )
      )
      [
        "user"
        "app"
        "service"
        "store"
      ];

  preserved = lib.filter (entity: entity.principal.state.preserve) stateful;

  # Dependency: nixos/org/snapshot.nix snapshots these, and links any other as it is.
  snapshotting = [
    "btrfs"
    "zfs"
  ];
  under = mount: path: mount == "/" || path == mount || lib.hasPrefix "${mount}/" path;
  fsType =
    path:
    let
      mounts = lib.filter (fs: under fs.mountPoint path) (lib.attrValues config.fileSystems);
    in
    if mounts == [ ] then
      null
    else
      (lib.last (lib.sortOn (fs: builtins.stringLength fs.mountPoint) mounts)).fsType;
in
{
  imports = [
    ../preserve.nix
    ./snapshot.nix
    ./state-archive.nix
  ];

  assertions = map (entity: {
    assertion = entity.principal.state.preserve || entity.principal.state.archives == { };
    message = "${entity.handle} archives a home it doesn't preserve: set principal.state.preserve, or drop principal.state.archives.";
  }) stateful;

  warnings = lib.concatMap (
    entity:
    let
      data = config.o11n.preserve.onStorage entity.principal.home;
      type = fsType data;
    in
    lib.optional (entity.principal.state.archives != { } && !lib.elem type snapshotting)
      "${entity.handle}'s home, at ${data}, is on ${toString type}, which state-snapshot@ can't snapshot, so each archive of it reads it as it changes: put it on btrfs or zfs."
  ) stateful;

  o11n.preserve.directories = map (entity: {
    directory = entity.principal.home;
    user = entity.name;
    group = entity.name;
  }) preserved;

  o11n.snapshots = lib.listToAttrs (
    map (
      entity: lib.nameValuePair entity.handle (config.o11n.preserve.onStorage entity.principal.home)
    ) preserved
  );
}
