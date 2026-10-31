# tests/vm/remote-eval.nix
#
# gw evaluates and builds a stage of the org's flake at a revision, with its o11n input at
# another, for a client that names them with the bearer, and streams nix's output back with
# the exit status last. The org and a private input come over ssh with nix-remote's key, a
# revision on a branch included, one evaluation runs at a time, and one whose client leaves
# stops. It needs KVM, so it isn't among the checks: nix-remote.sh build .#vmTests.remote-eval
{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;

  # The org's flake is a private repository on gw here, which it fetches over ssh as it would
  # the real one.
  org = outputs.org // {
    repository = {
      type = "git";
      url = "ssh://git@localhost/srv/org";
    };
  };
  inherit (org.host.gw) endpoint;

  certificate = pkgs.runCommand "certificate" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj /CN=${endpoint} -addext subjectAltName=DNS:${endpoint} \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  flake = value: pkgs.writeText "flake.nix" ''{ outputs = _: { value = "${value}"; }; }'';
in
pkgs.testers.runNixOSTest {
  name = "o11n-remote-eval";

  node.specialArgs = { inherit org o11nInputs; };

  nodes.gw = {
    imports = [
      o11nInputs.sops-nix.nixosModules.sops
      ../../nixos/preserve.nix
      ../../nixos/org/remote-builder.nix
    ];
    _module.args.host = org.host.gw;

    # The sample's committed root identity reads every secret. sops-nix refuses a key file in
    # the store.
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

    # As nixos/org/networking.nix routes the services' addresses.
    boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
    networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";

    # As nixos/org/principals.nix makes it.
    users.users.nix-remote = {
      isSystemUser = true;
      group = "nix-remote";
      inherit (org.service.nix-remote.principal) uid;
    };
    users.groups.nix-remote = { };

    # Where the org and its private input are, readable with nix-remote's key alone.
    services.openssh.enable = true;
    users.users.git = {
      isSystemUser = true;
      group = "git";
      shell = pkgs.bash;
      openssh.authorizedKeys.keyFiles = [ org.service.nix-remote.publicKeys.ssh-key ];
    };
    users.groups.git = { };

    # Without ACME, a certificate the client trusts.
    services.nginx.virtualHosts.${endpoint} = {
      enableACME = lib.mkForce false;
      sslCertificate = "${certificate}/cert.pem";
      sslCertificateKey = "${certificate}/key.pem";
    };
    security.pki.certificateFiles = [ "${certificate}/cert.pem" ];
    networking.hosts."127.0.0.1" = [ endpoint ];

    nix.package = pkgs.lix;
    nix.settings.substituters = lib.mkForce [ ];
    systemd.services."nix-remote-eval@".environment.HEARTBEAT = lib.mkForce "1";

    environment.systemPackages = [
      pkgs.git
      (pkgs.callPackage ../../packages/o11n-tools.nix {
        o11n = pkgs.callPackage ../../packages/o11n.nix { };
      })
    ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = ''
    import json

    bearer = "-H \"Authorization: Bearer $(cat /run/secrets/nix-remote/secret-key)\""
    client = "cd /root/org && O11N_REMOTE_BUILDER=https://${endpoint} O11N_REMOTE_BUILDER_TOKEN=$(cat /run/secrets/nix-remote/secret-key)"

    def run(user, path, command):
        return gw.succeed(f"cd {path} && runuser -u {user} -- env HOME=/tmp {command}").strip()

    def commit(user, path, message):
        run(user, path, "git add -A")
        run(user, path, f"git -c user.name={user} -c user.email={user}@example.org commit -qm {message}")
        return run(user, path, "git rev-parse HEAD")

    def evaluate(path):
        return gw.succeed(f"curl -sSN {bearer} https://${endpoint}/nix-eval/{path}")

    def status(path, auth=bearer):
        return gw.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {auth} https://${endpoint}/nix-eval/{path}")

    gw.wait_for_unit("nginx.service")
    gw.wait_for_unit("sshd.service")
    gw.wait_for_unit("nix-remote-eval.socket")

    gw.succeed("install -d -o nix-remote -g nix-remote /srv/o11n")
    gw.succeed("install -d -o git -g git /srv/private /srv/org")
    for user, path in [("nix-remote", "/srv/o11n"), ("git", "/srv/org"), ("git", "/srv/private")]:
        run(user, path, "git init -q -b main")

    gw.succeed("cp ${flake "one"} /srv/o11n/flake.nix")
    one = commit("nix-remote", "/srv/o11n", "one")
    gw.succeed("cp ${flake "two"} /srv/o11n/flake.nix")
    commit("nix-remote", "/srv/o11n", "two")
    gw.succeed("cp ${flake "private"} /srv/private/flake.nix")
    commit("git", "/srv/private", "private")
    # Locked as an org's flake is, with nix-remote's key. The private input then leaves the store,
    # for the evaluation to fetch it over ssh itself.
    gw.succeed("git config --global --add safe.directory '*'")
    gw.succeed("cp ${./remote-eval-org.nix} /srv/org/flake.nix")
    run("git", "/srv/org", "git add flake.nix")
    gw.succeed(
        "cd /srv/org && GIT_SSH_COMMAND='ssh -i /run/secrets/nix-remote/ssh-key -o StrictHostKeyChecking=accept-new'"
        " nix --extra-experimental-features 'nix-command flakes' flake lock"
    )
    org = commit("git", "/srv/org", "org")
    archive = gw.succeed("nix --extra-experimental-features 'nix-command flakes' flake archive --json /srv/org")
    gw.succeed(f"nix-store --delete {json.loads(archive)['inputs']['private']['path']}")

    with subtest("only a request with the bearer, for a stage and whole revisions, gets through"):
        assert status(f"ok/{org}", auth="") == "401"
        out = evaluate("ok/0123abc")
        assert "usage: GET /nix-eval/<stage>/<org revision>" in out, out

    with subtest("a stage is built at the org's revision, its private input fetched with nix-remote's key"):
        out = evaluate(f"ok/{org}")
        assert "o11n two, private" in out, out
        assert out.splitlines()[-1] == "nix-remote-eval: exit 0", out

    with subtest("a revision on another branch than the repository's default is fetched too"):
        run("git", "/srv/org", "git checkout -q -b work")
        run("git", "/srv/org", "sh -c 'echo work >notes'")
        work = commit("git", "/srv/org", "work")
        run("git", "/srv/org", "git checkout -q main")
        out = evaluate(f"ok/{work}")
        assert out.splitlines()[-1] == "nix-remote-eval: exit 0", out

    with subtest("nix-remote.sh has o11n at another revision, and exits as nix did"):
        gw.succeed("git clone -q /srv/org /root/org")
        out = gw.succeed(f"{client} nix-remote.sh eval ok {one} 2>&1")
        assert "o11n one, private" in out, out
        assert "nix-remote-eval: exit" not in out, out
        out = gw.fail(f"{client} nix-remote.sh eval fails 2>&1")
        assert "failing" in out, out

    with subtest("a stage's output that is a file comes back, built before or not"):
        for _ in range(2):
            out = evaluate(f"report/{org}")
            assert out.splitlines()[-2:] == ["reported", "nix-remote-eval: exit 0"], out

    with subtest("a stage the org doesn't have fails with nix's error"):
        out = evaluate(f"missing/{org}")
        assert "does not provide attribute" in out, out
        assert out.splitlines()[-1] == "nix-remote-eval: exit 1", out

    with subtest("one evaluation runs at a time, and one whose client leaves stops"):
        gw.succeed(f"systemd-run --unit=slow-client --setenv=PATH=$PATH sh -c 'curl -sSN {bearer} https://${endpoint}/nix-eval/slow/{org} >/tmp/slow.log 2>&1'")
        try:
            gw.wait_until_succeeds("grep -q 'nix-remote-eval: running for' /tmp/slow.log")
            gw.wait_until_succeeds("pgrep -f '[w]hile :'")
        finally:
            print(gw.execute("cat /tmp/slow.log")[1])
        assert status(f"ok/{org}") == "409"
        gw.succeed("systemctl stop slow-client")
        gw.wait_until_succeeds(f"test $(curl -s -o /dev/null -w '%{{http_code}}' {bearer} https://${endpoint}/nix-eval/ok/{org}) = 200")
        gw.wait_until_fails("pgrep -f '[w]hile :'")
  '';
}
