{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (outputs) org;
  inherit (org.app) auth photos;
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

  picture = pkgs.runCommand "red.jpg" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    magick -size 16x16 xc:red $out
  '';

  # Fact: the box's server and the apps' endpoints, as the internet's DNS would answer.
  resolving =
    { nodes, ... }:
    {
      networking.hosts = {
        ${nodes.mx.networking.primaryIPAddress} = [ "mx.example.com" ];
        ${nodes.web.networking.primaryIPAddress} = [
          auth.endpoint
          photos.endpoint
        ];
      };
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
    };

  immich =
    {
      config,
      lib,
      org,
      pkgs,
      ...
    }:
    import ../../nixos/apps/immich.nix {
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
        systemd.tmpfiles.rules = [ "d ${share} 0700 alice alice - -" ];
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
        ]
        ++ map principal (org.host.web.principals ++ [ photos ]);
        _module.args = {
          # Accommodating for the inventory, whose photos runs on no host: here, web has it as a principal.
          host = org.host.web // {
            principals = org.host.web.principals ++ [ photos ];
          };
          app = auth;
        };
        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
        };
        # Accommodating for the test's network, which has no ACME server: the test's CA signs photos' certificate.
        services.nginx.virtualHosts.${photos.endpoint} = {
          enableACME = lib.mkForce false;
          sslCertificate = "${tls}/${photos.endpoint}.crt";
          sslCertificateKey = "${tls}/${photos.endpoint}.key";
        };
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
        virtualisation.memorySize = 4096;
        virtualisation.cores = 2;
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

    with subtest("the box is alice's library, mounted as the app's user"):
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

    with subtest("a Keycloak user with a box logs in, and what they upload is filed in it"):
        member("alice")
        session = login("alice")
        assert not session["isAdmin"], session
        me = answer("alice", "GET", "users/me")
        assert me["storageLabel"] == "alice" and me["quotaSizeInBytes"] is None, me
        body, status = upload("alice")
        assert status == "201", f"{status} {body}"
        mx.wait_until_succeeds("test -f ${share}/2024/2024-05-06/red.jpg", timeout=120)

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
        assert [asset["originalFileName"] for asset in assets["assets"]["items"]] == ["red.jpg"], assets
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
  '';
}
