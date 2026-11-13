{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  # Fact: the mail inventory's nextcloud, with users of its own rather than auth's realm's, which vmTests.keycloak runs,
  # and storages as org/apps/nextcloud.nix derives them for nextcloud.storages.bob.pub.bind = "/srv/pub" and
  # nextcloud.storages.rolf.home.adapter = "app-site", site's home /var/lib/site.
  cloud = lib.recursiveUpdate org.app.cloud {
    nextcloud = {
      client = null;
      users = {
        bob = false;
        rolf = true;
      };
      adapters = [
        {
          user = "rolf";
          path = "/var/lib/site";
          owner = "site";
        }
      ];
      binds = [
        {
          mountPoint = "/pub";
          user = "bob";
          sharing = false;
          path = "/srv/pub";
        }
      ];
    };
  };
  dav = "${cloud.url}/remote.php/dav/files/bob";
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared) tls inventorySecrets principal;
  occ = "nixos-container run ${cloud.name} -- nextcloud-occ";

  nextcloud =
    {
      config,
      host,
      lib,
      org,
      pkgs,
      ...
    }:
    import ../../nixos/apps/nextcloud.nix {
      app = cloud;
      inherit
        config
        host
        lib
        org
        pkgs
        ;
    };
in
pkgs.testers.runNixOSTest {
  name = "o11n-drive";

  imports = [ ./timeout.nix ];
  globalTimeout = 900;

  node.specialArgs = { inherit org o11nInputs; };

  nodes.web =
    { lib, nodes, ... }:
    {
      imports = [
        inventorySecrets
        ../../nixos/preserve.nix
        nextcloud
        (principal cloud)
      ];
      _module.args.host = org.host.web;
      networking.hosts.${nodes.web.networking.primaryIPAddress} = [ cloud.endpoint ];
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
      };
      # Accommodating for the test's network, which has no ACME server: the test's CA signs the drive's certificate.
      services.nginx.virtualHosts.${cloud.endpoint} = {
        enableACME = lib.mkForce false;
        sslCertificate = "${tls}/${cloud.endpoint}.crt";
        sslCertificateKey = "${tls}/${cloud.endpoint}.key";
      };
      # Accommodating for the test's network, whose addresses are private, which nextcloud fetches from only when let.
      containers.${cloud.name}.config = {
        networking.hosts.${nodes.web.networking.primaryIPAddress} = [ cloud.endpoint ];
        security.pki.certificateFiles = [ "${tls}/ca.crt" ];
        services.nextcloud.settings.allow_local_remote_servers = true;
      };
      # Accommodating for the test's network, which has no wg0: the principal binds to its loopback address as
      # nixos/org/networking.nix routes it.
      networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
      boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
      users.users.site = {
        isSystemUser = true;
        group = "site";
        home = "/var/lib/site";
        createHome = true;
      };
      users.groups.site = { };
      systemd.tmpfiles.rules = [ "d /srv/pub 0750 ${cloud.name} ${cloud.name} - -" ];
      environment.systemPackages = [ pkgs.poppler-utils ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
    };

  testScript = ''
    start_all()
    for unit in ["nextcloud-office", "coolwsd"]:
        web.wait_until_succeeds(f"nixos-container run ${cloud.name} -- systemctl is-active {unit}.service", timeout=600)

    with subtest("the drive serves its office at its own endpoint, from coolwsd in its container"):
        discovery = web.wait_until_succeeds("curl -sSf ${cloud.url}/hosting/discovery", timeout=120)
        assert "${cloud.url}/browser/" in discovery, discovery

    with subtest("nextcloud keeps its office's discovery, which it opens a document with"):
        assert web.succeed("${occ} config:app:get richdocuments public_wopi_url").strip() == "${cloud.url}"

    with subtest("the office converts a document, as it opens one, in the container"):
        web.succeed("printf 'Hello from the drive\\n' > /tmp/hello.txt")
        web.succeed("curl -sSf -F data=@/tmp/hello.txt ${cloud.url}/cool/convert-to/pdf -o /tmp/hello.pdf")
        assert "Hello from the drive" in web.succeed("pdftotext /tmp/hello.pdf -"), "the office didn't convert"

    with subtest("the drive's home is made anew as it starts, and its database keeps what's its own"):
        web.succeed("nixos-container run ${cloud.name} -- env OC_PASS=alice-password nextcloud-occ user:resetpassword --password-from-env bob")
        web.succeed("${occ} tag:add kept public")
        version = web.succeed("${occ} config:system:get version").strip()
        web.succeed("nixos-container run ${cloud.name} -- touch /var/lib/nextcloud/made-before")
        web.succeed("systemctl restart container@${cloud.name}.service")
        try:
            web.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-office.service", timeout=120)
        except Exception:
            print(web.execute("journalctl -M ${cloud.name} -u nextcloud-setup --no-pager | tail -40")[1])
            raise
        web.fail("nixos-container run ${cloud.name} -- test -e /var/lib/nextcloud/made-before")
        web.succeed("nixos-container run ${cloud.name} -- sh -c 'test -s /var/lib/nextcloud/data/appdata_*/richdocuments/remoteData/discovery'")
        assert web.succeed("${occ} config:system:get version").strip() == version
        web.succeed("${occ} user:info bob")
        assert "kept" in web.succeed("${occ} tag:list"), "the tag is gone"

    def put(path, body):
        return web.succeed(
            f"printf %s {body} | curl -s -o /dev/null -w '%{{http_code}}' -u bob:alice-password -T - '${dav}/{path}'"
        ).strip()

    with subtest("a user without a box has files no one can write in, and each of their storages a folder in them"):
        web.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-external.service", timeout=120)
        root = put("root.txt", "root")
        assert root != "201", f"bob wrote in his files, which have no box: {root}"
        pub = put("pub/kept.txt", "kept")
        assert pub == "201", f"bob couldn't write in his bind: {pub}"
        assert web.succeed("cat /srv/pub/kept.txt").strip() == "kept"

    with subtest("what changes in a bind's directory, nextcloud sees as the folder is opened, and it outlives a restart"):
        # Accommodating for nextcloud, which tells a folder changed by its mtime, in whole seconds.
        web.sleep(1)
        web.succeed("runuser -u ${cloud.name} -- sh -c 'echo host > /srv/pub/from-host.txt'")
        listed = web.succeed("curl -sSf -u bob:alice-password -X PROPFIND -H 'Depth: 1' '${dav}/pub/'")
        assert "from-host.txt" in listed, listed
        web.succeed("systemctl restart container@${cloud.name}.service")
        web.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-external.service", timeout=300)
        assert web.succeed("curl -sSf -u bob:alice-password '${dav}/pub/kept.txt'").strip() == "kept"

    with subtest("an adapter is a user's home, their owner's, which nextcloud writes in as the owner, and reads the owner's in"):
        web.succeed("nixos-container run ${cloud.name} -- env OC_PASS=rolf-password nextcloud-occ user:resetpassword --password-from-env rolf")
        rolf = "curl -sS -u rolf:rolf-password"
        written = web.succeed(
            f"printf written | {rolf} -o /dev/null -w '%{{http_code}}' -T - '${cloud.url}/remote.php/dav/files/rolf/written.txt'"
        ).strip()
        assert written == "201", f"rolf couldn't write in his home: {written}"
        assert web.succeed("stat -c %U:%G /var/lib/site/files/written.txt").strip() == "site:site"
        web.sleep(1)
        web.succeed("runuser -u site -- sh -c 'echo site > /var/lib/site/files/from-site.txt'")
        listed = web.succeed(f"{rolf} -f -X PROPFIND -H 'Depth: 1' '${cloud.url}/remote.php/dav/files/rolf/'")
        assert "from-site.txt" in listed, listed
        said = web.succeed("nextcloud-status-${cloud.name}")
        assert "${cloud.name} home rolf ok" in said.splitlines(), said
  '';
}
