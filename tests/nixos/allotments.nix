{
  pkgs,
  lib,
}:
let
  allotment = {
    entity = "user-alice";
    host = "web";
    size = "1G";
    path = "/srv/allotments/user-alice";
    replicas = [ ];
    torrent = false;
    logins = { };
  };

  # Accommodating for the module's shape, which follows from `host`: it comes as a specialArg, as o11n passes it.
  cfg =
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit pkgs lib;
      inherit (pkgs.stdenv.hostPlatform) system;
      specialArgs = {
        host = {
          name = "web";
          allotments = [ allotment ];
          replicas = [ ];
          principals = [ ];
        };
        org.entities.user-alice = {
          name = "alice";
          principal = {
            uid = 1000;
            gid = 1000;
          };
        };
      };
      modules = [
        ../../nixos/org/allotments.nix
        { system.stateVersion = lib.trivial.release; }
      ];
    }).config;
in
{
  # Policy: a host without a ZFS dataset at its storage is refused, rather than given a directory without a quota.
  test_without_zfs_refused = {
    expr = {
      failing = map (assertion: assertion.message) (
        lib.filter (
          assertion: !assertion.assertion && lib.hasPrefix "allotment." assertion.message
        ) cfg.assertions
      );
      inherit (cfg.o11n) allotments;
    };
    expected = {
      failing = [
        "allotment.\"user-alice@web\": web keeps allotments under the ZFS dataset its disk layouts mount at o11n.preserve.storage, /srv/storage, and they have none: give web a disk layout with one, or put the allotment on another host."
      ];
      allotments = { };
    };
  };
}
