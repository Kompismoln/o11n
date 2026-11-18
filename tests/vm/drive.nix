{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  # Fact: the mail inventory's drive, with users of its own rather than auth's realm's, which vmTests.keycloak runs,
  # and storages and roots as org/apps/drive.nix derives them for storages.bob.pub.bind = "/srv/pub" and
  # roots.rolf = "app-site", site's home /var/lib/site, and storages.bob.Bilder.library = "photos", whose root of bob
  # is photos/ in box's share on mx.
  box = org.entities.store-box;
  library = "/srv/box/alice/photos";
  cloud = lib.recursiveUpdate org.app.cloud {
    client = null;
    users = {
      bob = false;
      rolf = true;
    };
    homes = [
      {
        user = "rolf";
        path = "/var/lib/site/drive";
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
    libraries = [
      {
        mountPoint = "/Bilder";
        user = "bob";
        sharing = false;
        photos = "photos";
        inherit (box.smb) host login;
        share = "${box.smb.share}/photos";
        key = {
          inherit (box) handle;
          secret = {
            name = "${box.name}/smb-password";
            inherit (box.secrets) sopsFile;
          };
        };
      }
    ];
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
    import ../../nixos/apps/drive.nix {
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

  # Fact: a storage box, whose share alice's is, which logs in as alice with the store's smb-password, and holds a
  # library Immich has filed.
  nodes.mx =
    { config, ... }:
    {
      imports = [ inventorySecrets ];
      sops.secrets."box/smb-password".sopsFile = box.secrets.sopsFile;
      users.users.alice = {
        isSystemUser = true;
        group = "alice";
      };
      users.groups.alice = { };
      systemd.tmpfiles.rules = [
        "d /srv/box/alice 0700 alice alice - -"
        "d ${library} 0700 alice alice - -"
        "d ${library}/2024 0700 alice alice - -"
        "d ${library}/2024/2024-05-06 0700 alice alice - -"
        "f ${library}/2024/2024-05-06/red.jpg 0600 alice alice - red"
      ];
      services.samba = {
        enable = true;
        openFirewall = true;
        settings = {
          global = {
            "server min protocol" = "SMB3_11";
            "server smb encrypt" = "required";
          };
          alice = {
            path = "/srv/box/alice";
            "read only" = "no";
            "valid users" = "alice";
          };
        };
      };
      systemd.services.samba-password = {
        before = [ "samba-smbd.service" ];
        requiredBy = [ "samba-smbd.service" ];
        path = [ config.services.samba.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          password=$(<${config.sops.secrets."box/smb-password".path})
          printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a alice
        '';
      };
    };

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
      networking.hosts = {
        ${nodes.web.networking.primaryIPAddress} = [ cloud.endpoint ];
        ${nodes.mx.networking.primaryIPAddress} = [ box.smb.host ];
      };
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
    mx.start()
    mx.wait_for_unit("samba-smbd.service")
    web.start()
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

    with subtest("a user without a root has files no one can write in, and each of their storages a folder in them"):
        web.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-external.service", timeout=120)
        root = put("root.txt", "root")
        assert root != "201", f"bob wrote in their files, which have no root: {root}"
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

    with subtest("a root in an entity's home is the entity's, which nextcloud writes in as the entity, and reads the entity's in"):
        web.succeed("nixos-container run ${cloud.name} -- env OC_PASS=rolf-password nextcloud-occ user:resetpassword --password-from-env rolf")
        rolf = "curl -sS -u rolf:rolf-password"
        written = web.succeed(
            f"printf written | {rolf} -o /dev/null -w '%{{http_code}}' -T - '${cloud.url}/remote.php/dav/files/rolf/written.txt'"
        ).strip()
        assert written == "201", f"rolf couldn't write in their root: {written}"
        assert web.succeed("stat -c %U:%G /var/lib/site/drive/files/written.txt").strip() == "site:site"
        web.sleep(1)
        web.succeed("runuser -u site -- sh -c 'echo site > /var/lib/site/drive/files/from-site.txt'")
        listed = web.succeed(f"{rolf} -f -X PROPFIND -H 'Depth: 1' '${cloud.url}/remote.php/dav/files/rolf/'")
        assert "from-site.txt" in listed, listed
        said = web.succeed("nextcloud-status-${cloud.name}")
        assert "${cloud.name} root rolf ok" in said.splitlines(), said

    with subtest("a library is read-only in nextcloud, as Immich filed it, and what's filed there after shows"):
        for folder, held in [("", "2024/"), ("2024/", "2024-05-06/"), ("2024/2024-05-06/", "red.jpg")]:
            listed = web.succeed(f"curl -sSf -u bob:alice-password -X PROPFIND -H 'Depth: 1' '${dav}/Bilder/{folder}'")
            assert f"/Bilder/{folder}{held}<" in listed, listed
        assert web.succeed("curl -sSf -u bob:alice-password '${dav}/Bilder/2024/2024-05-06/red.jpg'").strip() == "red"
        written = put("Bilder/written.txt", "written")
        assert not written.startswith("2"), f"bob wrote in his library: {written}"
        deleted = web.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -u bob:alice-password -X DELETE '${dav}/Bilder/2024/2024-05-06/red.jpg'"
        ).strip()
        assert not deleted.startswith("2"), f"bob deleted from his library: {deleted}"
        mx.succeed("test -f ${library}/2024/2024-05-06/red.jpg && ! test -e ${library}/written.txt")
        web.sleep(1)
        mx.succeed("install -o alice -g alice -m 0600 /dev/null ${library}/2024/2024-05-06/blue.jpg")
        web.wait_until_succeeds(
            "curl -sSf -u bob:alice-password -X PROPFIND -H 'Depth: 1' '${dav}/Bilder/2024/2024-05-06/' | grep -q blue.jpg",
            timeout=30,
        )
  '';
}
