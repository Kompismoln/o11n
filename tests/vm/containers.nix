# tests/vm/containers.nix
#
# Ephemeral containers on storage, btrfs and zfs: NixOS makes /var/empty immutable inside a
# container, so nspawn can't remove the snapshot it ran in, and nixos/containers.nix does. And a
# container that uses the host's postgresql through a bind of /run/postgresql comes back with it
# whichever way postgresql goes down, a move of its WAL included. It needs KVM, so it isn't
# among the checks: nix-remote.sh build .#vmTests.containers
{ pkgs }:
let
  inherit (pkgs) lib;

  common = {
    imports = [ ../../nixos/containers.nix ];
    o11n.preserve.enable = true;
    virtualisation.emptyDiskImages = [ 1024 ];
    environment.systemPackages = [ pkgs.e2fsprogs ];
  };

  container = {
    ephemeral = true;
    config = {
      system.stateVersion = lib.trivial.release;
      environment.systemPackages = [ pkgs.postgresql ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "o11n-containers";

  node.specialArgs = {
    org = {
      postgres = "17";
      app = { };
    };
    host.name = "btrfs";
  };

  nodes = {
    btrfs = {
      imports = [
        common
        ../../nixos/postgresql.nix
      ];
      virtualisation.memorySize = 2048;
      boot.supportedFilesystems = [ "btrfs" ];
      virtualisation.fileSystems."/srv/storage" = {
        device = "/dev/vdb";
        fsType = "btrfs";
        autoFormat = true;
      };

      users.users.probe = {
        isSystemUser = true;
        group = "probe";
        home = "/var/lib/probe";
        createHome = true;
      };
      users.groups.probe = { };

      o11n.postgresql = {
        databases.probe = { };
        containers = [ "app" ];
      };
      services.postgresql.authentication = lib.mkForce "local all all trust";

      containers.app = container // {
        autoStart = true;
        bindMounts."/run/postgresql".isReadOnly = false;
      };

      specialisation.wal.configuration.o11n.preserve.postgresqlWal = "/srv/wal";
    };

    zfs = {
      imports = [ common ];
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "8425e349";
      containers.app = container // {
        autoStart = false;
      };
    };
  };

  testScript = ''
    import re

    storage = "/srv/storage/var/lib/nixos-containers"


    def entries(machine, pattern):
        return [e for e in machine.succeed(f"ls -A {storage}").split() if re.fullmatch(pattern, e)]


    def snapshots(machine):
        return entries(machine, r"\.#snapshot\.app[0-9a-f]{16}")


    def locks(machine):
        return entries(machine, r"\.#\.#snapshot\.app[0-9a-f]{16}\.lck")


    def invocation(machine):
        return machine.succeed("systemctl show -p InvocationID --value container@app.service").strip()


    def restarted(machine, before):
        machine.wait_until_succeeds(
            f"test \"$(systemctl show -p InvocationID --value container@app.service)\" != {before}"
        )
        machine.wait_for_unit("container@app.service")


    def running_snapshot(machine):
        [snapshot] = snapshots(machine)
        flags = machine.succeed(f"lsattr -d '{storage}/{snapshot}/var/empty'").split()[0]
        assert flags[4] == "i", f"/var/empty in {snapshot} isn't immutable: {flags}"
        assert len(locks(machine)) == 1, locks(machine)
        return snapshot


    def reboots_and_stops(machine):
        old = running_snapshot(machine)
        before = invocation(machine)
        machine.succeed("machinectl reboot app")
        restarted(machine, before)
        new = running_snapshot(machine)
        assert new != old, new

        machine.succeed("systemctl stop container@app.service")
        assert snapshots(machine) == [], snapshots(machine)
        assert locks(machine) == [], locks(machine)


    def cleans_up_after_a_crash(machine):
        stale = f"{storage}/.#snapshot.app0123456789abcdef"
        other = f"{storage}/.#snapshot.app-dev0123456789abcdef"
        for snapshot in [stale, other]:
            machine.succeed(f"mkdir -p '{snapshot}/var/empty'", f"chattr +i '{snapshot}/var/empty'")
        machine.succeed(f"touch '{storage}/.#.#snapshot.app0123456789abcdef.lck'")

        machine.succeed("systemctl start container@app.service")
        machine.wait_for_unit("container@app.service")
        machine.fail(f"test -e '{stale}'")
        machine.fail(f"test -e '{storage}/.#.#snapshot.app0123456789abcdef.lck'")
        machine.succeed(f"test -d '{other}'")
        running_snapshot(machine)


    def reaches_postgresql():
        btrfs.wait_until_succeeds(
            "nixos-container run app -- psql -h /run/postgresql -U postgres -tAc 'select 1' | grep -qx 1"
        )


    def started_after_postgresql():
        postgresql = int(btrfs.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value postgresql.service"))
        app = int(btrfs.succeed("systemctl show -p InactiveExitTimestampMonotonic --value container@app.service"))
        assert postgresql <= app, (postgresql, app)


    start_all()

    with subtest("btrfs: the container starts from storage after postgresql"):
        btrfs.wait_for_unit("container@app.service")
        btrfs.succeed("findmnt -no FSTYPE /srv/storage | grep -qx btrfs")
        running_snapshot(btrfs)
        started_after_postgresql()
        reaches_postgresql()

    with subtest("btrfs: a reboot inside the container and a stop leave no snapshot behind"):
        reboots_and_stops(btrfs)

    with subtest("btrfs: a start removes what a crash left, and only that container's"):
        cleans_up_after_a_crash(btrfs)
        reaches_postgresql()

    with subtest("a restart of postgresql restarts the container"):
        before = invocation(btrfs)
        btrfs.succeed("systemctl restart postgresql.service")
        restarted(btrfs, before)
        reaches_postgresql()

    with subtest("a crash of postgresql restarts the container"):
        before = invocation(btrfs)
        btrfs.succeed("systemctl kill -s KILL postgresql.service")
        restarted(btrfs, before)
        reaches_postgresql()

    with subtest("a stop of postgresql stops the container, and its start brings it back"):
        btrfs.succeed("systemctl stop postgresql.service")
        btrfs.fail("systemctl is-active container@app.service")
        btrfs.succeed("systemctl start postgresql.service")
        btrfs.wait_for_unit("container@app.service")
        started_after_postgresql()
        reaches_postgresql()

    with subtest("after the host reboots, the container starts after postgresql from a clean root"):
        btrfs.shutdown()
        btrfs.start()
        btrfs.wait_for_unit("container@app.service")
        running_snapshot(btrfs)
        started_after_postgresql()
        reaches_postgresql()

    with subtest("moving the WAL restarts postgresql, and the container comes back"):
        btrfs.succeed("psql -h /run/postgresql -U postgres -c 'create table kept (x int); insert into kept values (42)'")
        before = invocation(btrfs)
        btrfs.succeed("/run/booted-system/specialisation/wal/bin/switch-to-configuration test")
        btrfs.succeed("test \"$(readlink /srv/database/var/lib/postgresql/17/pg_wal)\" = /srv/wal/17")
        btrfs.fail("test -e /srv/database/var/lib/postgresql/17/pg_wal.moved")
        restarted(btrfs, before)
        reaches_postgresql()
        btrfs.succeed("test \"$(psql -h /run/postgresql -U postgres -tAc 'select x from kept')\" = 42")

    with subtest("zfs: the same, on a pool"):
        zfs.wait_for_unit("multi-user.target")
        zfs.succeed(
            "zpool create -m none tank /dev/vdb",
            "zfs create -o mountpoint=/srv/storage -o overlay=on tank/storage",
            "systemd-tmpfiles --create --prefix /srv/storage",
        )
        zfs.succeed("findmnt -no FSTYPE /srv/storage | grep -qx zfs")
        zfs.succeed("systemctl start container@app.service")
        zfs.wait_for_unit("container@app.service")
        reboots_and_stops(zfs)
        cleans_up_after_a_crash(zfs)
  '';
}
