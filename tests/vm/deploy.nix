# tests/vm/deploy.nix
#
# A deploy on the sample org: the operator builds on gw over ssh-ng as the untrusted
# nix-build, web substitutes from gw's nix-serve and switches with switch-system, and
# o11n-tools' apply.sh does the same with the sample's keys. It needs KVM, so it isn't
# among the checks: nix-remote.sh build .#vmTests.deploy
{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  sshKeys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  hello =
    name:
    pkgs.writeText "${name}.nix" ''
      derivation {
        name = "${name}";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "echo ${name} > $out" ];
      }
    '';

  deployUser = name: rec {
    isSystemUser = true;
    group = name;
    shell = pkgs.bashInteractive;
    inherit (org.service.${name}.principal) home;
    createHome = home != "/var/empty";
    openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
    openssh.authorizedKeys.keyFiles = [ org.service.${name}.publicKeys.ssh-key ];
  };

  # Stands in for the org's flake, for the tooling.
  standIns = [
    "web"
    "other"
    "stranded"
  ];
  orgFlake = pkgs.runCommand "org" { } ''
    mkdir $out
    cp ${./stand-in.nix} $out/stand-in.nix
    cp ${pkgs.writeText "flake.nix" ''
      {
        outputs = _: {
          nixosConfigurations = builtins.listToAttrs (map (name: {
            inherit name;
            value.config.system.build.toplevel = import ./stand-in.nix name;
          }) (builtins.fromJSON '''${builtins.toJSON standIns}'''));
        };
      }
    ''} $out/flake.nix
  '';

  orgExport = pkgs.writeText "org-export.json" (builtins.toJSON outputs.org.export);

  # Without their context, so that the test doesn't build them itself.
  standIn = lib.genAttrs standIns (
    name:
    lib.mapAttrs (_: builtins.unsafeDiscardStringContext) {
      inherit (import ./stand-in.nix name) drvPath outPath;
    }
  );

  peer =
    hostName:
    { nodes, ... }:
    {
      imports = [ ../../nixos/org/nix.nix ];
      _module.args.host = org.host.${hostName};
      services.openssh.enable = true;
      users.groups = lib.genAttrs [ "nix-build" "nix-switch" "nix-push" ] (_: { });
      users.users = lib.genAttrs [ "nix-build" "nix-switch" "nix-push" ] deployUser;
      networking.hosts.${nodes.gw.networking.primaryIPAddress} = [ "gw.sample" ];
      virtualisation.memorySize = 2048;
    };
in
pkgs.testers.runNixOSTest {
  name = "o11n-deploy";

  node.specialArgs = {
    inherit org o11nInputs;
    inherit (outputs.context) inputs;
  };

  nodes = {
    gw =
      { nodes, ... }:
      {
        imports = [
          (peer "gw")
          o11nInputs.sops-nix.nixosModules.sops
          ../../nixos/org/nix-serve.nix
        ];
        # The sample's committed root identity can read every secret, nix-serve's key too.
        # sops-nix refuses a key file in the store.
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
        networking.firewall.allowedTCPPorts = [ 5000 ];
        # Only gw has web's next system, so web has to substitute it.
        virtualisation.additionalPaths = [ nodes.web.system.build.next ];
      };

    web =
      { extendModules, ... }:
      {
        imports = [ (peer "web") ];
        # Test VMs leave out switch-to-configuration unless asked, and boot without a
        # bootloader, so there is none to install when switching.
        system.switch.enable = true;
        boot.loader.grub.enable = false;
        system.build.next =
          (extendModules {
            modules = [ { environment.etc.next.text = "next"; } ];
          }).config.system.build.toplevel;
      };

    operator = {
      # As on the org's hosts, where operators run the tools.
      nix.package = pkgs.lix;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      environment.systemPackages = [
        (pkgs.callPackage ../../packages/o11n-tools.nix {
          o11n = pkgs.callPackage ../../packages/o11n.nix { };
        })
        pkgs.gettext
        pkgs.git
      ];
      environment.etc."nix/inputs/self".source = outputs.context.path;
      environment.etc.org.source = orgFlake;
      environment.etc."hello-1.nix".source = hello "hello-1";
      environment.etc."unsigned.nix".source = hello "unsigned";
      programs.ssh.extraConfig = ''
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel ERROR
      '';
    };
  };

  testScript =
    { nodes, ... }:
    let
      next = nodes.web.system.build.next;
    in
    ''
      start_all()
      gw.wait_for_unit("sshd.service")
      gw.wait_for_unit("nix-serve.service")
      web.wait_for_unit("sshd.service")
      operator.wait_for_unit("multi-user.target")
      operator.succeed(
        "install -Dm600 ${sshKeys.snakeOilPrivateKey} /root/.ssh/id_ed25519"
      )

      store = "ssh-ng://nix-build@gw"

      # A test VM boots its system without a profile; give it a first generation.
      web.succeed("nix-env -p /nix/var/nix/profiles/system --set $(readlink -f /run/current-system)")
      first = web.succeed("readlink /nix/var/nix/profiles/system").strip().split("-")[1]

      with subtest("nix-build reaches gw's daemon as an untrusted user"):
          info = operator.succeed(f"nix store ping --store {store} 2>&1")
          assert "Trusted: 0" in info, info

      with subtest("the operator evaluates, gw builds and keeps the result"):
          hello1 = operator.succeed(
              f"nix build --eval-store auto --store {store} -f /etc/hello-1.nix --no-link --print-out-paths"
          ).strip()
          gw.succeed(f"nix-store --check-validity {hello1}")
          operator.fail(f"nix-store --check-validity {hello1}")

      with subtest("gw doesn't import what the operator built"):
          unsigned = operator.succeed("nix-build /etc/unsigned.nix --no-out-link").strip()
          out = operator.fail(f"nix copy --to {store} {unsigned} 2>&1")
          assert "signature" in out, out

      with subtest("switch-system realises from gw, and refuses what isn't a system"):
          web.fail(f"nix-store --check-validity {hello1}")
          out = operator.fail(f"ssh -n nix-switch@web {hello1} 2>&1")
          assert "is not a NixOS system" in out, out
          web.succeed(f"nix-store --check-validity {hello1}")

      with subtest("nix-build gets the daemon, whatever it asks for"):
          operator.execute("ssh -n nix-build@gw touch /tmp/ran")
          gw.fail("test -e /tmp/ran")

      # switch-to-configuration reloads every user manager, and fails on one that is stopping.
      web.wait_until_fails("systemctl is-active --quiet user@$(id -u nix-switch).service")

      with subtest("switch-system switches web to a system only gw has"):
          web.fail("nix-store --check-validity ${next}")
          operator.succeed("ssh -n nix-switch@web ${next}")
          web.succeed("test \"$(readlink -f /run/current-system)\" = ${next}")
          web.succeed("grep -qx next /etc/next")

      with subtest("switch-system switches to a generation, and lists them"):
          operator.succeed(f"ssh -n nix-switch@web {first}")
          web.fail("test -e /etc/next")
          out = operator.succeed("ssh -n nix-switch@web")
          assert "(current)" in out, out
          operator.fail("ssh -n nix-switch@web --rollback")

      with subtest("build-system takes a flake in the store and a host, and nothing else"):
          absent = "${builtins.storeDir}/00000000000000000000000000000000-source"
          for args in ["/etc/org web", f"{absent} web --impure", f"{absent} web#x", absent]:
              out = operator.fail(f"ssh -n nix-build@gw build-system {args} 2>&1")
              assert "usage: build-system" in out, out
          out = operator.fail(f"ssh -n nix-build@gw build-system {absent} web 2>&1")
          assert "is not valid" in out, out

      tools = "cd /root/org && O11N_EXPORT=${orgExport} SOPS_AGE_KEY_FILE=/etc/nix/inputs/self/keys/root-1 TARGET_ADDRESS=web"
      operator.succeed(
          "rm /root/.ssh/id_ed25519",
          "cp -rL /etc/org /root/org && chmod -R u+w /root/org",
          "cd /root/org && git init -q && git add -A && git -c user.name=o -c user.email=o@o commit -qm org",
      )

      with subtest("apply.sh has the first build host evaluate and build, and the target substitutes"):
          out = operator.fail(f"{tools} BUILD_HOST_ADDRESS=gw apply.sh web < /dev/null 2>&1")
          assert "is not a NixOS system" in out, out
          gw.succeed("nix-store --check-validity ${standIn.web.drvPath} ${standIn.web.outPath}")
          web.succeed("nix-store --check-validity ${standIn.web.outPath}")
          operator.fail("nix-store --check-validity ${standIn.web.drvPath}")
          operator.fail("nix-store --check-validity ${standIn.web.outPath}")

      with subtest("apply.sh says so when the target can't fetch the build"):
          gw.systemctl("stop nix-serve.service")
          out = operator.fail(f"{tools} BUILD_HOST_ADDRESS=gw apply.sh stranded < /dev/null 2>&1")
          assert "stranded couldn't fetch the build from gw" in out, out
          gw.systemctl("start nix-serve.service")
          gw.wait_for_open_port(5000)

      with subtest("build.sh says so when the build host has no build-system"):
          out = operator.fail(f"{tools} BUILD_HOST_ADDRESS=web build.sh web < /dev/null 2>&1")
          assert "gw has no build-system" in out, out

      with subtest("build.sh builds only on the org's build hosts"):
          out = operator.fail(f"{tools} BUILD_HOST=web build.sh web < /dev/null 2>&1")
          assert "web is not in build-hosts" in out, out

      with subtest("apply.sh with BUILD_HOST=localhost builds here and copies as nix-push"):
          out = operator.fail(f"{tools} BUILD_HOST=localhost apply.sh other < /dev/null 2>&1")
          assert "is not a NixOS system" in out, out
          operator.succeed("nix-store --check-validity ${standIn.other.outPath}")
          web.succeed("nix-store --check-validity ${standIn.other.outPath}")
          gw.fail("nix-store --check-validity ${standIn.other.outPath}")
    '';
}
