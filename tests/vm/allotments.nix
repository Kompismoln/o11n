{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "o11n-allotments";

  imports = [ ./timeout.nix ];
  globalTimeout = 300;

  nodes.machine = {
    imports = [ ../../nixos/allotments.nix ];
    virtualisation.emptyDiskImages = [ 512 ];
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.extraPools = [ "tank" ];
    # Fact: the test disk has no /dev/disk/by-id link, where zpool import looks by default.
    boot.zfs.devNodes = "/dev";
    networking.hostId = "8425e349";
    o11n.allotments.user-alice = {
      dataset = "tank/storage/allotments/user-alice";
      size = "64M";
      path = "/srv/allotments/user-alice";
      uid = 1000;
      gid = 1000;
    };
  };

  testScript = ''
    def prop(name):
        return machine.succeed(f"zfs get -H -o value {name} tank/storage/allotments/user-alice").strip()

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "zpool create -O mountpoint=none tank /dev/vdb",
        "zfs create -o mountpoint=/srv/storage tank/storage",
    )

    with subtest("a dataset of its own, under an unmounted parent, at its path and owned by the principal"):
        machine.succeed("systemctl restart allotment@user-alice")
        assert prop("refquota") == "64M", prop("refquota")
        assert prop("mountpoint") == "/srv/allotments/user-alice", prop("mountpoint")
        assert machine.succeed("zfs get -H -o value canmount tank/storage/allotments").strip() == "off"
        found = machine.succeed("stat -c '%u:%g %a' /srv/allotments/user-alice").strip()
        assert found == "1000:1000 700", found
        machine.fail("test -e /srv/storage/allotments")

    with subtest("it holds no more than its size"):
        machine.fail("dd if=/dev/urandom of=/srv/allotments/user-alice/fill bs=1M count=128")
        machine.succeed("rm /srv/allotments/user-alice/fill")

    with subtest("run again, it keeps what's in it and its size as declared"):
        machine.succeed(
            "echo kept > /srv/allotments/user-alice/file",
            "zfs set refquota=1G tank/storage/allotments/user-alice",
            "chmod 0755 /srv/allotments/user-alice",
            "systemctl restart allotment@user-alice",
        )
        assert prop("refquota") == "64M", prop("refquota")
        assert machine.succeed("stat -c %a /srv/allotments/user-alice").strip() == "700"
        assert machine.succeed("cat /srv/allotments/user-alice/file").strip() == "kept"

    with subtest("it outlasts a boot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("allotment@user-alice.service")
        assert machine.succeed("cat /srv/allotments/user-alice/file").strip() == "kept"
  '';
}
