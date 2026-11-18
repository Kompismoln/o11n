{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (outputs) org;
  inherit (org.app) auth;
  # Fact: the inventory's photos, with a drop folder of alice's as org/apps/drive.nix derives it for the drive cloud's
  # storages.alice.Bilder.photos = "photos", and cloud, with users of its own rather than auth's realm's, whose alice
  # has the drop folder and a bind of /srv/pub, pub.
  drop = "${org.app.photos.principal.home}/drop/alice/cloud/Bilder";
  drops = [
    {
      mountPoint = "/Bilder";
      user = "alice";
      sharing = false;
      photos = "photos";
      drive = "cloud";
      path = drop;
      owner = "photos";
    }
  ];
  photos = org.app.photos // {
    inherit drops;
  };
  cloud = pkgs.lib.recursiveUpdate org.app.cloud {
    client = null;
    users.alice = false;
    binds = [
      {
        mountPoint = "/pub";
        user = "alice";
        sharing = false;
        path = "/srv/pub";
      }
    ];
    inherit drops;
  };
  dav = "${cloud.url}/remote.php/dav/files/alice";
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared)
    tls
    inventorySecrets
    principal
    ;
  realm = "example";
  local = "http://[${auth.principal.bindAddress}]:8080";
  box = org.entities.store-box;
  share = "/srv/box/alice";
  root = "${share}/photos";

  pictureOf =
    colour:
    pkgs.runCommand "${colour}.jpg" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
      magick -size 16x16 xc:${colour} $out
    '';
  picture = pictureOf "red";

  # Fact: the box's server and the apps' endpoints, as the internet's DNS would answer.
  resolving =
    { nodes, ... }:
    {
      networking.hosts = {
        ${nodes.mx.networking.primaryIPAddress} = [ "mx.example.com" ];
        ${nodes.web.networking.primaryIPAddress} = [
          auth.endpoint
          photos.endpoint
          cloud.endpoint
        ];
      };
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
    };

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

  immich =
    {
      config,
      lib,
      org,
      pkgs,
      ...
    }:
    import ../../nixos/apps/photos.nix {
      app = photos;
      inherit
        config
        lib
        org
        pkgs
        ;
    };
in
pkgs.testers.runNixOSTest {
  name = "o11n-photos";

  imports = [ ./timeout.nix ];
  globalTimeout = 1200;

  node.specialArgs = { inherit org o11nInputs; };

  nodes = {
    # Fact: a storage box, whose share alice's is, which logs in as alice with the store's smb-password.
    mx =
      { config, ... }:
      {
        imports = [
          inventorySecrets
          resolving
        ];
        sops.secrets."box/smb-password".sopsFile = box.secrets.sopsFile;
        users.users.alice = {
          isSystemUser = true;
          group = "alice";
        };
        users.groups.alice = { };
        systemd.tmpfiles.rules = [
          "d ${share} 0700 alice alice - -"
          "d ${root} 0700 alice alice - -"
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
              path = share;
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

    web =
      { lib, nodes, ... }:
      {
        imports = [
          inventorySecrets
          resolving
          ../../nixos/preserve.nix
          ../../nixos/org/mail.nix
          ../../nixos/apps/keycloak.nix
          immich
          nextcloud
        ]
        ++ map principal (
          org.host.web.principals
          ++ [
            photos
            cloud
          ]
        );
        _module.args = {
          # Accommodating for the inventory, whose photos and cloud run on no host: here, web has them as principals.
          host = org.host.web // {
            principals = org.host.web.principals ++ [
              photos
              cloud
            ];
          };
          app = auth;
        };
        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
        };
        # Accommodating for the test's network, which has no ACME server: the test's CA signs the apps' certificates.
        services.nginx.virtualHosts = lib.genAttrs [ photos.endpoint cloud.endpoint ] (endpoint: {
          enableACME = lib.mkForce false;
          sslCertificate = "${tls}/${endpoint}.crt";
          sslCertificateKey = "${tls}/${endpoint}.key";
        });
        # Accommodating for the test's network, whose addresses are private, which nextcloud fetches from only when let.
        containers.${cloud.name}.config = {
          networking.hosts.${nodes.web.networking.primaryIPAddress} = [ cloud.endpoint ];
          security.pki.certificateFiles = [ "${tls}/ca.crt" ];
          services.nextcloud.settings.allow_local_remote_servers = true;
        };
        systemd.tmpfiles.rules = [ "d /srv/pub 0750 ${cloud.name} ${cloud.name} - -" ];
        # Accommodating for the test's network, whose hosts the container resolves as the host does, and which has
        # no internet to fetch machine learning's models from.
        containers.photos.config = {
          networking.hosts.${nodes.web.networking.primaryIPAddress} = [ auth.endpoint ];
          services.immich = {
            machine-learning.enable = false;
            settings.machineLearning.enabled = false;
          };
        };
        # Accommodating for the test's CA, which Keycloak doesn't read from the host's bundle, as it calls photos
        # back to log out.
        services.keycloak.settings.truststore-paths = "${tls}/ca.crt";
        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
        # Accommodating for the test's network, which has no wg0: the principals bind to their loopback addresses as
        # nixos/org/networking.nix routes them.
        networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
        boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
        environment.systemPackages = [ pkgs.jq ];
        virtualisation.memorySize = 8192;
        virtualisation.diskSize = 4096;
        virtualisation.cores = 4;
      };
  };

  testScript = ''
    import html
    import json
    import re

    def token():
        return web.succeed(
            "tr -d '\\n' < /run/secrets/auth/admin-client-secret"
            " | curl -sSf -H 'X-Forwarded-Proto: https' ${local}/realms/master/protocol/openid-connect/token"
            " -d grant_type=client_credentials -d client_id=o11n --data-urlencode client_secret@-"
            " | jq -r .access_token"
        ).strip()

    def keycloak(method, path, body=None):
        data = f" -H 'Content-Type: application/json' --data-binary @- <<'EOF'\n{json.dumps(body)}\nEOF" if body else ""
        return web.succeed(
            f"curl -sSf -X {method} -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}'"
            f" ${local}/admin/realms/${realm}/{path}{data}"
        )

    def member(name):
        keycloak("POST", "users", {
            "username": name, "email": f"{name}@example.com", "emailVerified": True,
            "firstName": name.capitalize(), "lastName": "Example", "enabled": True,
            "credentials": [{"type": "password", "value": f"{name}'s", "temporary": False}],
        })

    def api(jar, method, path, *args):
        return web.succeed(
            f"curl -sS -b /tmp/{jar} -c /tmp/{jar} -X {method} -w '\\n%{{http_code}}' ${photos.url}/api/{path} "
            + " ".join(args)
        ).rsplit("\n", 1)

    def answer(jar, method, path, *args):
        body, status = api(jar, method, path, *args)
        assert status.startswith("2"), f"{method} {path}: {status} {body}"
        return json.loads(body) if body else None

    def login(name):
        authorize = answer(
            name, "POST", "oauth/authorize", "-H 'Content-Type: application/json'",
            "--data-raw '{\"redirectUri\": \"${photos.url}/auth/login\"}'",
        )
        browse = f"curl -sS -b /tmp/{name} -c /tmp/{name} -L"
        page = web.succeed(f"{browse} '{authorize['url']}'")
        form = re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
        assert form, page[-500:]
        landed = web.succeed(
            f"{browse} -o /dev/null -w '%{{url_effective}}' --data-urlencode username={name}"
            f" --data-urlencode password=\"{name}'s\" '{html.unescape(form.group(1))}'"
        )
        assert landed.startswith("${photos.url}/auth/login?"), landed
        return answer(
            name, "POST", "oauth/callback", "-H 'Content-Type: application/json'",
            f"--data-raw '{json.dumps({'url': landed})}'",
        )

    def upload(name):
        return api(
            name, "POST", "assets",
            "-F 'assetData=@${picture};filename=red.jpg'", "-F deviceAssetId=red", "-F deviceId=test",
            "-F fileCreatedAt=2024-05-06T12:00:00.000Z", "-F fileModifiedAt=2024-05-06T12:00:00.000Z",
        )

    def sql(query):
        query = query.replace('"', '\\"')
        return web.succeed(
            f"nixos-container run photos -- runuser -u photos -- psql -h /run/postgresql -d photos -tAX -c \"{query}\""
        ).strip()

    mx.start()
    mx.wait_for_unit("samba-smbd.service")
    web.start()
    web.wait_for_unit("keycloak-realms.service", timeout=300)
    web.wait_until_succeeds("nixos-container run photos -- systemctl is-active immich-users.service", timeout=600)

    with subtest("alice's root is their library, mounted as the app's user"):
        web.succeed("mountpoint -q /var/lib/photos/immich/library/alice")
        owner = web.succeed("nixos-container run photos -- stat -c %U /var/lib/immich/library/alice").strip()
        assert owner == "photos", owner

    with subtest("a fresh install has the app as its admin, and the realm as the only way in"):
        config = answer("anyone", "GET", "server/config")
        assert config["isInitialized"], config
        features = answer("anyone", "GET", "server/features")
        assert features["oauth"] and features["oauthAutoLaunch"] and features["configFile"], features
        assert not features["passwordLogin"], features
        admins = sql('select email, "oauthId" from "user" where "isAdmin"')
        assert admins == "${photos.principal.mail.address}|o11n", admins
        _, status = api(
            "anyone", "POST", "auth/login", "-H 'Content-Type: application/json'",
            "--data-raw '{\"email\": \"${photos.principal.mail.address}\", \"password\": \"anything\"}'",
        )
        assert not status.startswith("2"), status

    def dropped(name, source):
        web.succeed(f"install -o photos -g photos -m 0640 {source} '${drop}/{name}'")

    def originals(user):
        return sql(
            'select "originalFileName" from asset join "user" on "user".id = asset."ownerId"'
            f" where \"storageLabel\" = '{user}' order by 1"
        ).split()

    with subtest("what's dropped for a user who hasn't logged in waits for them"):
        dropped("blue.jpg", "${pictureOf "blue"}")
        web.wait_until_succeeds(
            "nixos-container run photos -- journalctl -u immich-drop-alice | grep -q 'is no user of photos'", timeout=120
        )
        web.succeed("test -f '${drop}/blue.jpg'")

    with subtest("a Keycloak user with a box logs in, and what they upload is filed in it"):
        member("alice")
        session = login("alice")
        assert not session["isAdmin"], session
        me = answer("alice", "GET", "users/me")
        assert me["storageLabel"] == "alice" and me["quotaSizeInBytes"] is None, me
        body, status = upload("alice")
        assert status == "201", f"{status} {body}"
        mx.wait_until_succeeds("test -f ${root}/2024/2024-05-06/red.jpg", timeout=120)

    with subtest("what's dropped is taken into its user's library and deleted, and what Immich doesn't take stays"):
        dropped("green.jpg", "${pictureOf "green"}")
        dropped("red.jpg", "${picture}")
        dropped("notes.txt", "${pkgs.writeText "notes.txt" "notes"}")
        dropped("yellow.jpg.ocTransferId1.part", "${pictureOf "yellow"}")
        web.wait_until_succeeds(
            "! test -e '${drop}/green.jpg' && ! test -e '${drop}/blue.jpg' && ! test -e '${drop}/red.jpg'", timeout=120
        )
        assert originals("alice") == ["blue.jpg", "green.jpg", "red.jpg"], originals("alice")
        left = web.succeed("ls '${drop}'").split()
        assert left == ["notes.txt", "yellow.jpg.ocTransferId1.part"], left
        mx.wait_until_succeeds("ls ${root}/*/*/green.jpg", timeout=120)

    with subtest("a Keycloak user without a box logs in, and can upload nothing"):
        member("carol")
        login("carol")
        me = answer("carol", "GET", "users/me")
        assert me["quotaSizeInBytes"] == 0, me
        body, status = upload("carol")
        assert status == "400" and "Quota" in body, f"{status} {body}"

    with subtest("a quota or a storage label changed by hand is as declared"):
        sql("""update "user" set "quotaSizeInBytes" = null, "storageLabel" = 'other' where "storageLabel" = 'carol'""")
        held = sql("""select "storageLabel", "quotaSizeInBytes" from "user" where email = 'carol@example.com'""")
        assert held == "carol|0", held

    with subtest("the container made anew keeps the app's state, and makes no other admin"):
        web.succeed("systemctl restart container@photos.service")
        web.wait_until_succeeds("nixos-container run photos -- systemctl is-active immich-users.service", timeout=300)
        assets = answer("alice", "POST", "search/metadata", "-H 'Content-Type: application/json'", "--data-raw '{}'")
        names = sorted(asset["originalFileName"] for asset in assets["assets"]["items"])
        assert names == ["blue.jpg", "green.jpg", "red.jpg"], assets
        admins = sql('select count(*) from "user" where "isAdmin"')
        assert admins == "1", admins

    with subtest("logging out of the realm logs out of immich"):
        alice = json.loads(keycloak("GET", "users?username=alice&exact=true"))[0]
        keycloak("POST", f"users/{alice['id']}/logout")
        _, status = api("alice", "GET", "users/me")
        assert status == "401", status

    with subtest("an archive of the app's state leaves out what Immich makes anew"):
        ignored = web.succeed("cat /var/lib/photos/.resticignore")
        assert ignored == "immich/thumbs/\nimmich/encoded-video/\n", repr(ignored)

    with subtest("a root mounted anew, as a switch mounts it, is under a library the app's user owns, as root left it or not"):
        library = "/var/lib/photos/immich/library"
        web.succeed("systemctl stop container@photos.service photos-library.service")
        web.fail(f"mountpoint -q {library}/alice")
        web.succeed(f"chown root:root {library} && chmod 755 {library}")
        web.succeed(f"systemctl start $(systemd-escape -p --suffix=mount {library}/alice)")
        owners = web.succeed(f"stat -c '%U %a' {library} {library}/alice").split("\n")
        assert owners[:2] == ["photos 700", "photos 750"], owners
        web.succeed("systemctl start container@photos.service")
        web.wait_until_succeeds("nixos-container run photos -- systemctl is-active immich-users.service", timeout=300)

    with subtest("a write that pauses in a drop folder is taken only once it's done"):
        web.wait_until_succeeds("nixos-container run photos -- systemctl is-active immich-drop-alice.service", timeout=120)
        web.succeed("head -c 200000 /dev/urandom > /tmp/tail && cat ${pictureOf "orange"} /tmp/tail > /tmp/slow.jpg")
        size = web.succeed("stat -c %s /tmp/slow.jpg").strip()
        web.succeed(
            "runuser -u photos -- sh -c '"
            "exec 3>\"${drop}/slow.jpg\"; head -c 300 /tmp/slow.jpg >&3; sleep 12; tail -c +301 /tmp/slow.jpg >&3"
            "' >/dev/null 2>&1 &"
        )
        web.sleep(10)
        web.succeed("test -f '${drop}/slow.jpg'")
        web.wait_until_succeeds("! test -e '${drop}/slow.jpg'", timeout=120)
        filed = mx.succeed("stat -c %s $(ls ${root}/*/*/slow.jpg)").strip()
        assert filed == size, f"{filed} of {size} bytes filed"

    with subtest("a mixed folder the drive moves into a drop folder: its photos and videos taken, the rest left"):
        web.wait_until_succeeds("nixos-container run ${cloud.name} -- systemctl is-active nextcloud-external.service", timeout=600)
        web.succeed("nixos-container run ${cloud.name} -- env OC_PASS=alice-password nextcloud-occ user:resetpassword --password-from-env alice")
        before = len(originals("alice"))
        web.succeed(
            "runuser -u ${cloud.name} -- sh -c '"
            "cd /srv/pub && mkdir -p mixed/a/b mixed/c && "
            "for i in $(seq 300); do d=mixed/a; [ $((i % 3)) = 0 ] && d=mixed/a/b; [ $((i % 3)) = 1 ] && d=mixed/c; "
            "{ cat ${picture}; echo $i; } > $d/p$i.jpg; done && "
            "head -c 300M /dev/urandom > mixed/c/clip.mp4 && "
            "echo notes > mixed/notes.txt && echo doc > mixed/a/b/doc.pdf"
            "'"
        )
        curl = "curl -sS -u alice:alice-password"
        web.succeed(f"{curl} -f -X PROPFIND -H 'Depth: 1' '${dav}/pub/' -o /dev/null")
        moved = web.succeed(
            f"{curl} -w '\\n%{{http_code}}' -X MOVE -H 'Destination: ${dav}/Bilder/mixed' '${dav}/pub/mixed'"
        ).strip()
        assert moved.endswith("201"), f"the move answered {moved}"
        web.fail("test -e /srv/pub/mixed")
        web.wait_until_succeeds(
            "test -z \"$(find '${drop}/mixed' -type f \\( -name '*.jpg' -o -name '*.mp4' \\))\"", timeout=900
        )
        taken = len(originals("alice")) - before
        assert taken == 301, f"{taken} taken"
        left = sorted(web.succeed("cd '${drop}/mixed' && find . -type f").split())
        assert left == ["./a/b/doc.pdf", "./notes.txt"], left
        listed = web.succeed(f"{curl} -f -X PROPFIND -H 'Depth: 1' '${dav}/Bilder/mixed/'")
        assert "notes.txt" in listed, listed
        listed = web.succeed(f"{curl} -f -X PROPFIND -H 'Depth: 1' '${dav}/Bilder/mixed/c/'")
        assert "p1.jpg" not in listed and "clip.mp4" not in listed, listed
  '';
}
