# tests/vm/phone-home.nix
#
# The rescue stick calls gw's reverse tunnel: it is refused while closed, a wrong code doesn't
# get through or keep the right one from it, and with the right one gw reaches the stick's sshd
# with the rescue key. When the line expires the call stays up; when gw closes it, it ends. It
# needs KVM, so it isn't among the checks: nix-remote.sh build .#vmTests.phone-home
{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  enc = "${outputs.context.path}/enc";
in
pkgs.testers.runNixOSTest {
  name = "o11n-phone-home";

  node.specialArgs = { inherit org; };

  nodes = {
    gw = {
      imports = [
        o11nInputs.sops-nix.nixosModules.sops
        ../../nixos/org/ssh.nix
        ../../nixos/org/fail2ban.nix
        ../../nixos/org/reverse-tunnel.nix
      ];
      _module.args.host = org.host.gw;

      # As nixos/org/principals.nix makes it.
      users.mutableUsers = false;
      users.users.reverse-tunnel = {
        isSystemUser = true;
        group = "reverse-tunnel";
      };
      users.groups.reverse-tunnel = { };

      # The sample's committed root identity reads gw's host key and the rescue key.
      # sops-nix refuses a key file in the store.
      system.activationScripts = {
        sample-age-key = lib.stringAfter [ "specialfs" ] ''
          install -m 400 ${outputs.context.path}/keys/root-1 /run/sample-age-key
        '';
        setupSecrets.deps = [ "sample-age-key" ];
      };
      sops = {
        age = {
          keyFile = "/run/sample-age-key";
          sshKeyPaths = [ ];
        };
        secrets = {
          host-key = {
            sopsFile = "${enc}/host-gw.yaml";
            key = "ssh-key";
            path = "/keys/ssh_host_ed25519_key";
          };
          rescue-key = {
            sopsFile = "${enc}/service-rescue.yaml";
            key = "rescue/ssh-key";
          };
        };
      };
    };

    stick =
      { nodes, ... }:
      {
        imports = [ ../../nixos/org/rescue-usb.nix ];
        o11n.rescue-usb.via = "gw";
        # It's on the wire already, so phonehome skips the wifi.
        networking.networkmanager.enable = lib.mkForce false;
        networking.hosts.${nodes.gw.networking.primaryIPAddress} = [ org.host.gw.endpoint ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import shlex
      from datetime import timedelta

      def say(*lines):
          stick.succeed("printf '%s\\n' " + " ".join(map(shlex.quote, lines)) + " >> /tmp/phonehome.in")

      def heard(text, times=1):
          stick.wait_until_succeeds(f"[ $(grep -c {shlex.quote(text)} /tmp/phonehome.out) -ge {times} ]", timeout=timedelta(seconds=90))

      ssh_stick = "ssh -i /run/secrets/rescue-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2603 root@localhost"

      start_all()
      gw.wait_for_unit("sshd.service")
      gw.wait_for_unit("fail2ban.service")
      stick.wait_for_unit("sshd.service")

      with subtest("closed until opened"):
          gw.fail("systemctl is-active reverse-tunnel.service")
          gw.succeed("reverse-tunnel status | grep -x closed")
          stick.succeed("touch /tmp/phonehome.in")
          stick.succeed("systemd-run --unit phonehome --setenv=PATH=/run/current-system/sw/bin sh -c 'tail -f /tmp/phonehome.in | phonehome > /tmp/phonehome.out 2>&1'")
          say("1111 2222 3333")
          heard("The line isn't open")

      with subtest("a wrong code doesn't get through"):
          print(gw.succeed("reverse-tunnel open 1234-5678-9012"))
          gw.wait_for_open_port(2602)
          say("")
          heard("That code didn't work")

      with subtest("the right code does, and gw reaches the stick with the rescue key"):
          say("123456789012")
          heard("Connected!")
          gw.wait_for_open_port(2603)
          gw.succeed("reverse-tunnel status | grep -q connected")
          hostname = gw.succeed(f"{ssh_stick} hostname").strip()
          assert hostname == "rescue-usb", hostname
          # fail2ban took the wrong code for an attack on sshd, which is all it guards.
          banned = gw.succeed("fail2ban-client get sshd banned")
          assert "${nodes.stick.networking.primaryIPAddress}" in banned, banned

      with subtest("the line expires without hanging up"):
          gw.succeed("systemctl start reverse-tunnel-expire.service")
          gw.fail("systemctl is-active reverse-tunnel.service")
          gw.succeed("grep -q '^reverse-tunnel:!:' /etc/shadow")
          gw.succeed(f"{ssh_stick} true")

      with subtest("closing it hangs up, and the stick can't call back in"):
          gw.succeed("reverse-tunnel close")
          gw.wait_for_closed_port(2603)
          heard("The connection dropped")
          heard("The line isn't open", times=2)
          print(stick.succeed("cat /tmp/phonehome.out"))
    '';
}
