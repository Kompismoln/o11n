{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "o11n-snapshot";

  imports = [ ./timeout.nix ];
  globalTimeout = 180;

  nodes.machine = {
    imports = [ ../../nixos/org/snapshot.nix ];
    virtualisation.emptyDiskImages = [
      512
      512
    ];
    boot.supportedFilesystems = [
      "btrfs"
      "zfs"
    ];
    networking.hostId = "8425e349";
    environment.systemPackages = [ pkgs.btrfs-progs ];
    o11n.snapshots = {
      user-alice = "/srv/btrfs/home/alice";
      app-bob = "/srv/zfs/bob";
      user-carol = "/var/lib/carol";
    };
  };

  testScript = ''
    def snapshot(id, expected):
        machine.succeed(f"systemctl start state-snapshot@{id}")
        found = machine.succeed(f"cat /run/o11n/state/{id}/state").strip()
        assert found == expected, found

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "mkfs.btrfs /dev/vdb",
        "mkdir -p /srv/btrfs && mount /dev/vdb /srv/btrfs",
        "mkdir -p /srv/btrfs/home/alice && echo one > /srv/btrfs/home/alice/state",
        "zpool create -O mountpoint=/srv/zfs tank /dev/vdc",
        "mkdir /srv/zfs/bob && echo one > /srv/zfs/bob/state",
        "mkdir -p /var/lib/carol && echo one > /var/lib/carol/state",
    )

    with subtest("btrfs: one read-only snapshot of the subvolume the state is on, replaced by the next"):
        snapshot("user-alice", "one")
        machine.succeed("echo two > /srv/btrfs/home/alice/state")
        found = machine.succeed("cat /run/o11n/state/user-alice/state").strip()
        assert found == "one", found
        snapshot("user-alice", "two")
        subvolumes = machine.succeed("btrfs subvolume list -o /srv/btrfs").strip().splitlines()
        assert len(subvolumes) == 1 and subvolumes[0].endswith(" path .state/user-alice"), subvolumes
        machine.fail("touch /run/o11n/state/user-alice/written")

    with subtest("zfs: one snapshot of the dataset the state is on, replaced by the next"):
        snapshot("app-bob", "one")
        machine.succeed("echo two > /srv/zfs/bob/state")
        snapshot("app-bob", "two")
        snapshots = machine.succeed("zfs list -H -o name -t snapshot").split()
        assert snapshots == ["tank@state-app-bob"], snapshots

    with subtest("elsewhere, the state as it is"):
        snapshot("user-carol", "one")
        target = machine.succeed("readlink /run/o11n/state/user-carol").strip()
        assert target == "/var/lib/carol", target

    with subtest("an entity without state on the host fails"):
        machine.fail("systemctl start state-snapshot@user-nobody")
  '';
}
