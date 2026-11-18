{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (outputs) org;
  inherit (org.app)
    auth
    blog
    calendar
    cloud
    status
    www
    ;
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared)
    fqdn
    tls
    inventorySecrets
    principal
    ;
  realm = "example";
  local = "http://[${auth.principal.bindAddress}]:8080";
  orgExport = pkgs.writeText "org-export.json" (builtins.toJSON org.export);
  o11n = pkgs.callPackage ../../packages/o11n.nix { };

  # Fact: the mail server and the apps' endpoints, as the internet's DNS would answer.
  resolving =
    { nodes, ... }:
    {
      networking.hosts = {
        ${nodes.mx.networking.primaryIPAddress} = [ fqdn ];
        ${nodes.web.networking.primaryIPAddress} = [
          auth.endpoint
          cloud.endpoint
          status.endpoint
          www.endpoint
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

  portal =
    {
      lib,
      org,
      pkgs,
      ...
    }:
    import ../../nixos/apps/portal.nix {
      app = www;
      inherit lib org pkgs;
    };

  statusPage =
    {
      lib,
      org,
      ...
    }:
    import ../../nixos/apps/status.nix {
      app = status;
      host = org.host.web;
      inherit lib org;
    };

  # Fact: a visitor's browser, which runs the portal's script as it would, with nothing of the test's in between.
  visitor =
    pkgs.writers.writePython3Bin "visitor"
      {
        libraries = [ pkgs.python3Packages.playwright ];
        flakeIgnore = [ "E501" ];
      }
      ''
        import json
        import sys
        from playwright.sync_api import sync_playwright

        said = {}
        with sync_playwright() as p:
            # Accommodating for the inventory's portal, at http, where a browser has no WebCrypto, which PKCE takes,
            # unless the origin is taken as secure.
            browser = p.chromium.launch(channel="chromium", args=["--unsafely-treat-insecure-origin-as-secure=${www.url}"])
            # Accommodating for Chromium, which trusts its own store rather than the test's CA in the system's bundle.
            page = browser.new_page(ignore_https_errors=True)
            page.on("pageerror", lambda error: print("pageerror:", error, file=sys.stderr))
            page.set_default_timeout(15000)
            page.goto("${www.url}/en/blog/")
            page.click('[data-auth="login"]')
            page.fill("#username", "alice")
            page.fill("#password", sys.argv[1])
            page.click("#kc-login")
            page.wait_for_selector('[data-auth="name"]', state="visible")
            said["returned"] = page.url
            said["name"] = page.text_content('[data-auth="name"]')
            page.goto("${www.url}/en/")
            page.wait_for_selector('[data-auth="name"]', state="visible")
            said["invite_hidden"] = page.is_hidden("#invite")
            tab = page.context.new_page()
            tab.goto("${www.url}/en/blog/")
            tab.wait_for_selector('[data-auth="name"]', state="visible")
            tab.close()
            page.goto("${cloud.url}/login")
            page.wait_for_url("${cloud.url}/apps/**")
            said["sso"] = page.url
            page.goto("${www.url}/en/blog/")
            page.click('[data-auth="logout"]')
            page.wait_for_selector('[data-auth="login"]', state="visible")
            said["logged_out"] = page.url
            page.click('[data-auth="login"]')
            page.wait_for_selector("#username")
            said["asked_again"] = page.url.startswith("${auth.url}/realms/")
            page.goto("${cloud.url}/apps/files/")
            page.wait_for_selector("#username")
            said["cloud_logged_out"] = page.url.startswith("${auth.url}/realms/")
            browser.close()
        print(json.dumps(said))
      '';

  # Fact: one invited, who follows the link in their mail, sets their password, and goes on as Keycloak offers.
  invited =
    pkgs.writers.writePython3Bin "invited"
      {
        libraries = [ pkgs.python3Packages.playwright ];
        flakeIgnore = [ "E501" ];
      }
      ''
        import sys
        from playwright.sync_api import sync_playwright

        link, password = sys.argv[1:3]
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="chromium")
            page = browser.new_page()
            page.on("pageerror", lambda error: print("pageerror:", error, file=sys.stderr))
            page.set_default_timeout(15000)
            page.goto(link)
            proceed = page.get_by_text("Click here to proceed")
            if proceed.count():
                proceed.click()
            page.fill("#password-new", password)
            page.fill("#password-confirm", password)
            page.locator("[type=submit]").click()
            # Fact: the realm's profile asks for a name, which the invite leaves to them.
            page.fill("#firstName", "Auth")
            page.fill("#lastName", "Example")
            page.locator("[type=submit]").click()
            back = page.get_by_text("Back to Application")
            try:
                back.wait_for(timeout=5000)
                back.click()
            except Exception:
                pass
            page.wait_for_url("${www.url}/**")
            print(page.url)
            browser.close()
      '';
in
pkgs.testers.runNixOSTest {
  name = "o11n-keycloak";

  imports = [ ./timeout.nix ];
  globalTimeout = 600;

  node.specialArgs = { inherit org o11nInputs; };

  nodes = {
    mx = {
      imports = [
        inventorySecrets
        resolving
        shared.mailserver
        ../../nixos/preserve.nix
        shared.mailApp
        (principal org.app.mail)
      ];
      _module.args.host = org.host.mx;
      networking.firewall.allowedTCPPorts = [ 587 ];
      # Accommodating for the test's network, which has no DNS for rspamd to ask.
      services.rspamd.locals."options.inc".text = ''
        dns {
          nameservers = ["127.0.0.1"];
          timeout = 1s;
          retransmits = 0;
        }
      '';
    };

    web =
      { lib, nodes, ... }:
      {
        imports = [
          inventorySecrets
          resolving
          ../../nixos/preserve.nix
          ../../nixos/org/mail.nix
          ../../nixos/org/fail2ban.nix
          ../../nixos/apps/keycloak.nix
          nextcloud
          portal
          statusPage
          (principal cloud)
          (principal www)
          (principal org.user.alice)
          (principal blog)
          (principal calendar)
          (principal auth)
        ];
        _module.args = {
          host = org.host.web;
          app = auth;
        };
        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
        };
        # Accommodating for the test's network, which has no ACME server: the test's CA signs nextcloud's certificate,
        # which it serves over https, as user_oidc asks.
        services.nginx.virtualHosts.${cloud.endpoint} = {
          enableACME = lib.mkForce false;
          sslCertificate = "${tls}/${cloud.endpoint}.crt";
          sslCertificateKey = "${tls}/${cloud.endpoint}.key";
        };
        # Accommodating for the test's network, whose hosts the container resolves as the host does, and whose
        # addresses are private, which nextcloud fetches from only when let.
        containers.cloud.config = {
          networking.hosts.${nodes.web.networking.primaryIPAddress} = [ auth.endpoint ];
          services.nextcloud.settings.allow_local_remote_servers = true;
        };
        # Accommodating for the test's mail server, whose certificate is of the test's own CA, which Keycloak doesn't
        # read from the host's bundle.
        services.keycloak.settings.truststore-paths = "${tls}/ca.crt";
        systemd.tmpfiles.rules = [ "d /var/lib/cloud/alice 0750 cloud cloud - -" ];
        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
        # Accommodating for the test's network, which has no wg0: the principals bind to their loopback addresses as
        # nixos/org/networking.nix routes them.
        networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
        boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
        environment.systemPackages = [
          o11n
          pkgs.jq
          visitor
          invited
        ];
        environment.variables.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
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

    def admin(path):
        return json.loads(web.succeed(f"curl -sSf -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}' ${local}/admin/realms/{path}"))

    start_all()
    mx.wait_for_unit("postfix.service")
    mx.wait_for_unit("dovecot.service")
    mx.wait_for_open_unix_socket("/run/rspamd/rspamd-milter.sock")
    web.wait_for_unit("keycloak-realms.service", timeout=300)

    with subtest("the org's client bootstraps Keycloak, which has no admin password"):
        users = admin("master/users")
        assert users == [], users
        client = admin("master/clients?clientId=o11n")[0]
        account = admin(f"master/clients/{client['id']}/service-account-user")
        assert account["email"] == "${auth.principal.mail.address}", account

    with subtest("the org's client has the master realm's admin role in its scope, and no full scope"):
        assert not client["fullScopeAllowed"], client
        scope = admin(f"master/clients/{client['id']}/scope-mappings/realm")
        assert [role["name"] for role in scope] == ["admin"], scope

    with subtest("a declared realm is kept as declared, and mails as the app from the org's mail server"):
        settings = admin("${realm}")
        assert settings["displayName"] == "Example", settings
        assert not settings["registrationAllowed"] and not settings["editUsernameAllowed"], settings
        lasts = (settings["ssoSessionIdleTimeout"], settings["ssoSessionMaxLifespan"])
        assert lasts == (14 * 86400, 14 * 86400), lasts
        smtp = settings["smtpServer"]
        assert (smtp["host"], smtp["port"], smtp["from"], smtp["user"]) == (
            "${fqdn}", "587", "${auth.principal.mail.address}", "${auth.principal.mail.address}"
        ), smtp

    with subtest("a Keycloak without the org's client says what to make"):
        web.succeed("cp /run/secrets/auth/admin-client-secret /tmp/secret && echo wrong > /run/secrets/auth/admin-client-secret")
        web.fail("systemctl restart keycloak-realms.service")
        said = web.succeed("journalctl -b -u keycloak-realms.service")
        assert "Keycloak refuses o11n's login, 401" in said and "make o11n a client of the master realm" in said, said
        web.succeed("cp /tmp/secret /run/secrets/auth/admin-client-secret")

    def client(clientId):
        found = admin(f"${realm}/clients?clientId={clientId}")
        assert len(found) == 1, found
        return found[0]

    with subtest("an app that names the keycloak has the client its kind derives, in the realm it names"):
        meet = client("meet")
        assert meet["publicClient"] and meet["standardFlowEnabled"] and not meet["directAccessGrantsEnabled"], meet
        assert meet["redirectUris"] == ["https://meet.example.com/static/sso.html"], meet
        assert meet["attributes"]["pkce.code.challenge.method"] == "S256", meet
        assert not meet["fullScopeAllowed"], meet

    with subtest("a confidential client has its app's secret, which the keycloak's host decrypts"):
        cloud = client("cloud")
        assert not cloud["publicClient"], cloud
        assert not cloud["fullScopeAllowed"], cloud
        assert cloud["redirectUris"] == [
            "${cloud.url}/apps/user_oidc/code",
            "${cloud.url}/index.php/apps/user_oidc/code",
        ], cloud
        held = admin(f"${realm}/clients/{cloud['id']}/client-secret")["value"]
        assert held == web.succeed("cat /run/secrets/cloud/oidc-secret").strip(), held

    with subtest("a client made otherwise by hand is put back as declared, keeping what isn't declared of it"):
        meet["publicClient"] = False
        meet["redirectUris"] = ["https://elsewhere.example.com/*"]
        meet["description"] = "by hand"
        web.succeed(
            f"curl -sSf -X PUT -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}'"
            f" -H 'Content-Type: application/json' --data-binary @- ${local}/admin/realms/${realm}/clients/{meet['id']}"
            f" <<'EOF'\n{json.dumps(meet)}\nEOF"
        )
        web.succeed("systemctl restart keycloak-realms.service")
        kept = client("meet")
        assert kept["id"] == meet["id"], kept
        assert kept["publicClient"] and kept["redirectUris"] == ["https://meet.example.com/static/sso.html"], kept
        assert kept["description"] == "by hand", kept

    with subtest("keeping it again changes nothing that's declared"):
        web.succeed("systemctl restart keycloak-realms.service")
        assert admin("${realm}")["smtpServer"]["host"] == "${fqdn}"

    occ = "nixos-container run cloud -- nextcloud-occ"

    with subtest("nextcloud's login sends to the realm, which makes the Keycloak user nextcloud's user of their name"):
        for unit in ["nextcloud-oidc", "nextcloud-apps"]:
            web.wait_until_succeeds(f"nixos-container run cloud -- systemctl is-active {unit}.service", timeout=300)
        user = {
            "username": "alice", "email": "alice@example.com", "emailVerified": True,
            "firstName": "Alice", "lastName": "Example", "enabled": True,
            "credentials": [{"type": "password", "value": "alice's", "temporary": False}],
        }
        web.succeed(
            f"curl -sSf -X POST -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}'"
            f" -H 'Content-Type: application/json' --data-binary @- ${local}/admin/realms/${realm}/users"
            f" <<'EOF'\n{json.dumps(user)}\nEOF"
        )
        browse = "curl -sS -b /tmp/jar -c /tmp/jar -L"
        page = web.succeed(f"{browse} ${cloud.url}/login")
        form = re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
        assert form, page
        landed = web.succeed(
            f"{browse} -o /dev/null -w '%{{url_effective}}' --data-urlencode username=alice"
            f" --data-urlencode password=\"alice's\" '{html.unescape(form.group(1))}'"
        )
        assert landed.startswith("${cloud.url}/") and "/apps/files" in landed and "user_oidc" not in landed, landed
        users = json.loads(web.succeed(f"{occ} user:list --info --output=json"))
        assert list(users) == ["alice"] and users["alice"]["backend"] == "user_oidc", users

    with subtest("meet's tokens are for meet, which its prosody accepts, by a mapper that's kept as declared"):
        alice = admin("${realm}/users?username=alice")[0]
        meet = client("meet")
        models = f"${realm}/clients/{meet['id']}/protocol-mappers/models"

        def audience():
            token = admin(
                f"${realm}/clients/{meet['id']}/evaluate-scopes/generate-example-access-token?userId={alice['id']}&scope=openid"
            )
            aud = token.get("aud", [])
            return aud if isinstance(aud, list) else [aud]

        assert "meet" in audience(), audience()
        mapper = [model for model in admin(models) if model["name"] == "audience"][0]
        web.succeed(
            f"curl -sSf -X DELETE -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}'"
            f" ${local}/admin/realms/{models}/{mapper['id']}"
        )
        assert "meet" not in audience() and "account" not in audience(), audience()
        web.succeed("systemctl restart keycloak-realms.service")
        assert "meet" in audience(), audience()

    with subtest("the portal logs in with its client and back to where it was, which logs in and out of the realm's other apps"):
        said = json.loads(web.succeed("visitor \"alice's\""))
        assert said["returned"] == "${www.url}/en/blog/", said
        assert said["name"] == "Alice Example", said
        assert said["invite_hidden"], said
        assert said["sso"].startswith("${cloud.url}/apps/"), said
        assert said["logged_out"] == "${www.url}/en/blog/" and said["asked_again"], said
        assert said["cloud_logged_out"], said

    with subtest("the status page watches the apps of its groups, and the mail server's webmail and ports, and announces"):
        statuses = "curl -sSf http://${status.endpoint}/api/v1/endpoints/statuses"
        # Fact: Gatus checks first as it starts, before the apps answer, and again an interval later.
        web.wait_until_succeeds(f"{statuses} | jq -e 'length == 7 and all(.[]; .results[-1].success)'", timeout=300)
        announced = json.loads(web.succeed("curl -sSf http://${status.endpoint}/api/v1/config"))["announcements"]
        assert [a["message"] for a in announced] == ["The status page is up."], announced

    with subtest("a Keycloak user without storages logs in, writes nothing, and logs out"):
        carol = {
            "username": "carol", "email": "carol@example.com", "emailVerified": True,
            "firstName": "Carol", "lastName": "Example", "enabled": True,
            "credentials": [{"type": "password", "value": "carol's", "temporary": False}],
        }
        web.succeed(
            f"curl -sSf -X POST -H 'X-Forwarded-Proto: https' -H 'Authorization: Bearer {token()}'"
            f" -H 'Content-Type: application/json' --data-binary @- ${local}/admin/realms/${realm}/users"
            f" <<'EOF'\n{json.dumps(carol)}\nEOF"
        )
        browse = "curl -sS -b /tmp/carol -c /tmp/carol -L"
        page = web.succeed(f"{browse} ${cloud.url}/login")
        form = re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
        assert form, page
        landed = web.succeed(
            f"{browse} -o /dev/null -w '%{{url_effective}}' --data-urlencode username=carol"
            f" --data-urlencode password=\"carol's\" '{html.unescape(form.group(1))}'"
        )
        assert landed.startswith("${cloud.url}/") and "/apps/files" in landed, landed
        users = json.loads(web.succeed(f"{occ} user:list --info --output=json"))
        assert sorted(users) == ["alice", "carol"] and users["carol"]["backend"] == "user_oidc", users
        assert users["carol"]["quota"] == "0 B", users["carol"]
        password = web.succeed(f"{occ} --no-interaction user:auth-tokens:add carol").strip().splitlines()[-1]
        said = web.succeed(
            f"curl -sS -o /dev/null -w '%{{http_code}}' -u 'carol:{password}' -T /etc/hostname"
            " ${cloud.url}/remote.php/dav/files/carol/written"
        )
        assert said == "507", said
        files = web.succeed(f"{browse} ${cloud.url}/apps/files/")
        request = re.search(r'data-requesttoken="([^"]+)"', files)
        assert request, files[-500:]
        web.succeed(
            f"{browse} -o /dev/null -G --data-urlencode 'requesttoken={html.unescape(request.group(1))}' ${cloud.url}/logout"
        )
        page = web.succeed(f"{browse} ${cloud.url}/login")
        assert re.search(r'action="[^"]*login-actions/authenticate', page), page[-500:]

    with subtest("a user of nextcloud's own is disabled, and the realm's user takes no password"):
        web.succeed("nixos-container run cloud -- env OC_PASS=bob-password nextcloud-occ user:add --password-from-env bob")
        web.succeed("nixos-container run cloud -- systemctl restart nextcloud-oidc.service")
        bob = json.loads(web.succeed(f"{occ} user:info bob --output=json"))
        assert not bob["enabled"], bob
        dav = "curl -sS -o /dev/null -w '%{http_code}' -X PROPFIND"
        said = web.succeed(f"{dav} -u bob:bob-password ${cloud.url}/remote.php/dav/files/bob/")
        assert said == "401", said
        said = web.succeed(f"{dav} -u \"alice:alice's\" ${cloud.url}/remote.php/dav/files/alice/")
        assert said == "401", said

    with subtest("nextcloud keeps a drive's apps, from no app store"):
        enabled = json.loads(web.succeed(f"{occ} app:list --enabled --output=json"))["enabled"]
        assert "user_oidc" in enabled and "files_sharing" in enabled, enabled
        for other in ["calendar", "dashboard", "photos", "activity", "app_api"]:
            assert other not in enabled, enabled
        web.succeed(f"{occ} app:enable dashboard")
        web.succeed("nixos-container run cloud -- systemctl restart nextcloud-apps.service")
        enabled = json.loads(web.succeed(f"{occ} app:list --enabled --output=json"))["enabled"]
        assert "dashboard" not in enabled, enabled
        web.fail(f"{occ} app:install calendar")

    with subtest("config.php's secret is the app's secret-key, and its instanceid follows from the app's id"):
        held = web.succeed(f"{occ} config:system:get secret").strip()
        assert held == web.succeed("cat /run/secrets/cloud/secret-key").strip(), held
        assert web.succeed(f"{occ} config:system:get instanceid").strip() == "oc${cloud.ids.hex8}"
        web.succeed("nixos-container run cloud -- test -d /var/lib/nextcloud/data/appdata_oc${cloud.ids.hex8}")

    with subtest("o11n status has Keycloak mail the app over verified TLS, as the app"):
        out = web.succeed(
            "cd ${outputs.context.path} && O11N_ORG_ROOT=$PWD O11N_EXPORT=${orgExport}"
            " SOPS_AGE_KEY_FILE=$PWD/keys/root-1 o11n status app-auth 2>&1 || true"
        )
        assert "app-auth keycloak-mail ${realm} ok" in out, out
        assert "app-auth mail-login ${fqdn} ok" in out, out
        assert "app-auth url ${auth.url} ok" in out, out
        user, query = "-u ${auth.principal.mail.address}", "header from ${auth.principal.mail.address}"
        mx.wait_until_succeeds(f"doveadm search {user} {query} | grep -q .", timeout=60)

    tools = "cd ${outputs.context.path} && O11N_ORG_ROOT=$PWD O11N_EXPORT=${orgExport} SOPS_AGE_KEY_FILE=$PWD/keys/root-1"

    with subtest("o11n invites one: a user of the realm, mailed a link to set their password, which leads to the portal"):
        out = web.succeed(f"{tools} o11n invite ${auth.principal.mail.address} 2>&1")
        assert "invited ${auth.principal.mail.address} to ${realm} as auth" in out, out
        user = admin("${realm}/users?username=auth&exact=true")[0]
        assert user["email"] == "${auth.principal.mail.address}" and user["enabled"], user
        mailbox, query = "-u ${auth.principal.mail.address}", "header subject 'Update Your Account'"
        mx.wait_until_succeeds(f"doveadm search {mailbox} {query} | grep -q .", timeout=60)
        text = html.unescape(mx.succeed(f"doveadm fetch {mailbox} text.utf8 {query}"))
        link = re.search(r"${pkgs.lib.escapeRegex auth.url}/realms/${realm}/login-actions/action-token\?[^\s\"<>]+", text)
        assert link and "This link will expire within 7 days." in text, text
        landed = web.succeed(f"invited '{link.group(0)}' \"auth's\"").strip()
        assert landed.startswith("${www.url}/"), landed

    with subtest("o11n invites no one who has an account already"):
        out = web.fail(f"{tools} o11n invite alice@example.com 2>&1")
        assert "alice@example.com has an account in ${realm} already: alice" in out, out

    with subtest("a realm whose mail fails fails the check, with what Keycloak says"):
        mx.succeed("systemctl stop postfix.service")
        out = web.succeed(
            "cd ${outputs.context.path} && O11N_ORG_ROOT=$PWD O11N_EXPORT=${orgExport}"
            " SOPS_AGE_KEY_FILE=$PWD/keys/root-1 o11n status app-auth 2>&1 || true"
        )
        assert "app-auth keycloak-mail ${realm} fail: ${auth.url}/admin/realms/${realm}/testSMTPConnection answers 500" in out, out

    with subtest("an invite whose mail isn't sent is undone, so that it can be made again"):
        out = web.fail(f"{tools} o11n invite bob@example.com 2>&1")
        assert "execute-actions-email answers 500" in out, out
        assert admin("${realm}/users?username=bob&exact=true") == [], out

    with subtest("wrong passwords and unknown names ban their address, not the X-Forwarded-For it sends"):
        address = web.succeed("getent ahostsv4 mx | head -1 | cut -d' ' -f1").strip()
        login = (
            "curl -sS -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.9' -d grant_type=password"
            " -d client_id=admin-cli -d password=wrong ${auth.url}/realms/${realm}/protocol/openid-connect/token"
        )
        for name in ["alice", "nobody", "alice", "nobody", "alice"]:
            said = mx.succeed(f"{login} -d username={name}")
            assert said == "400", said
        web.wait_until_succeeds(f"fail2ban-client get keycloak-auth banned | grep -qF {address}", timeout=60)
        banned = web.succeed("fail2ban-client get keycloak-auth banned")
        assert "203.0.113.9" not in banned, banned
        web.succeed(f"${pkgs.nftables}/bin/nft list set inet f2b-table addr-set-keycloak-auth | grep -qF {address}")
        mx.fail("curl -sS --max-time 5 ${auth.url}/realms/${realm}")
  '';
}
