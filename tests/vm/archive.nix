{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  web = org.host.web.network.wg0;
  gw = org.host.gw.network.wg0;
  archive = web.principals.service-archive;

  # Accommodating for sops-nix, which refuses a key file in the store: the sample's committed
  # root identity, which reads every secret, is installed outside it.
  sampleSecrets = {
    imports = [ o11nInputs.sops-nix.nixosModules.sops ];
    system.activationScripts = {
      sample-age-key = lib.stringAfter [ "specialfs" ] ''
        install -m 400 ${outputs.context.path}/keys/root-1 /run/sample-age-key
      '';
      setupSecrets.deps = [ "sample-age-key" ];
    };
    sops.age = {
      keyFile = "/run/sample-age-key";
      sshKeyPaths = [ ];
    };
  };

  # Duplication: as nixos/org/principals.nix makes them.
  principal = entity: {
    users.users.${entity.name} = {
      isSystemUser = true;
      group = entity.name;
      inherit (entity.principal) uid home homeMode;
      createHome = entity.principal.home != "/var/empty";
    };
    users.groups.${entity.name}.gid = entity.principal.gid;
  };
in
pkgs.testers.runNixOSTest {
  name = "o11n-archive";

  imports = [ ./timeout.nix ];
  globalTimeout = 180;

  node.specialArgs = { inherit org; };

  nodes = {
    web = {
      imports = [
        sampleSecrets
        ../../nixos/services/archive.nix
        (principal org.service.archive)
        (principal org.store.archives)
      ];
      _module.args.host = org.host.web;
      # Accommodating for the test's network, which has no wg0: eth1 takes web's address on it, and web the
      # archive's, as nixos/org/networking.nix has it.
      networking.interfaces.eth1.ipv6.addresses = [
        {
          inherit (web) address;
          prefixLength = 64;
        }
      ];
      networking.localCommands = "ip -6 route replace local ${archive.address}/128 dev lo";
      networking.firewall.interfaces.eth1.allowedTCPPorts = [ 8000 ];
    };

    gw = {
      imports = [
        sampleSecrets
        ../../nixos/org/snapshot.nix
        ../../nixos/org/state-archive.nix
        (principal org.user.admin)
      ];
      _module.args.host = org.host.gw;
      o11n.snapshots.user-admin = org.user.admin.principal.home;
      virtualisation.emptyDiskImages = [ 512 ];
      virtualisation.fileSystems."/home" = {
        device = "/dev/vdb";
        fsType = "btrfs";
        autoFormat = true;
      };
      # Accommodating for the test's network, which has no wg0: gw routes the archive's address to web, as
      # nixos/org/wireguard.nix has it, and resolves the archive as its DNS does.
      networking.interfaces.eth1.ipv6 = {
        addresses = [
          {
            inherit (gw) address;
            prefixLength = 64;
          }
        ];
        routes = [
          {
            inherit (archive) address;
            prefixLength = 128;
            via = web.address;
          }
        ];
      };
      networking.hosts.${archive.address} = [ archive.fqdn ];
      environment.systemPackages = [ pkgs.restic ];
    };
  };

  testScript = ''
    import json

    def restic(user, repo, command, password="$(cat /run/secrets/admin/archive-passwd)"):
        return (
            f"RESTIC_PASSWORD_FILE=/run/secrets/admin/restic-key RESTIC_CACERT=${org.service.domain-sample.publicKeys.tls-cert} "
            f"RESTIC_REST_USERNAME={user} RESTIC_REST_PASSWORD={password} "
            f"restic -r rest:https://${archive.fqdn}:8000/{repo}/ {command}"
        )

    start_all()
    web.wait_for_unit("archive.socket")
    gw.wait_for_unit("multi-user.target")

    with subtest("an archive with a schedule has a timer"):
        gw.succeed("systemctl list-timers --all | grep -F 'state-archive@user-admin:web.timer'")

    with subtest("an entity archives its snapshot as its home, its repo created as it first does, in the archives store"):
        # Accommodating for the test's /home, mounted over the home activation made.
        gw.succeed(
            "mkdir -p /home/admin && cd /home/admin"
            " && printf '*.tmp\\n/cache\\n' > .resticignore"
            " && mkdir -p cache sub/cache && echo one > kept"
            " && touch a.tmp cache/y sub/b.tmp sub/cache/x sub/keep.tmp"
            " && printf '!keep.tmp\\n' > sub/.resticignore"
        )
        gw.succeed("systemctl start state-archive@user-admin:web")
        owner = web.succeed("stat -c '%U:%G %a' /var/lib/archives/repos/user-admin/config").strip()
        assert owner == "archive:archives 660", owner
        snapshots = json.loads(gw.succeed(restic("user-admin", "user-admin", "snapshots --json")))
        assert [s["paths"] for s in snapshots] == [["/home/admin"]], snapshots
        assert gw.succeed("readlink /run/o11n/state/user-admin").startswith("/home/.state/user-admin")

    with subtest("a .resticignore reads as a .gitignore, wherever it is"):
        files = set(gw.succeed(restic("user-admin", "user-admin", "ls latest")).split())
        expected = {
            "/home/admin/.resticignore",
            "/home/admin/kept",
            "/home/admin/sub/.resticignore",
            "/home/admin/sub/cache/x",
            "/home/admin/sub/keep.tmp",
        }
        found = {f for f in files if f.startswith("/home/admin/") and f.rpartition("/")[2] not in ("cache", "sub")}
        assert found == expected, found

    with subtest("each archive takes a snapshot of its own"):
        gw.succeed("echo two > /home/admin/kept")
        gw.succeed("systemctl start state-archive@user-admin:web")
        kept = gw.succeed(restic("user-admin", "user-admin", "dump latest /home/admin/kept")).strip()
        assert kept == "two", kept

    with subtest("nothing gets in but an entity with its archive-passwd, to its own repo"):
        gw.fail(restic("user-admin", "user-admin", "snapshots", password="wrong"))
        gw.fail(restic("user-admin", "user-other", "init"))
        status = gw.succeed(
            "curl -sk -o /dev/null -w '%{http_code}' https://${archive.fqdn}:8000/user-admin/config"
        )
        assert status == "401", status
  '';
}
