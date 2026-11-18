{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  inherit (org.user) admin alice;
  inherit (org.app) auth;
  reports = org.app.mail;
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared)
    fqdn
    tls
    inventorySecrets
    principal
    ;
  login = entity: entity.principal.mail.address;

  # Fact: the mail server's name, as the internet's DNS would answer it.
  resolving =
    { nodes, ... }:
    {
      networking.hosts.${nodes.mx.networking.primaryIPAddress} = [ fqdn ];
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
    };

  # Fact: a receiver's aggregate report on example.com, gzipped as most are, of mail from ip.
  report =
    name:
    {
      ip,
      spf,
      date ? "Wed, 18 Nov 2026 00:00:00 +0000",
    }:
    pkgs.runCommand "${name}.eml" { nativeBuildInputs = [ pkgs.gzip ]; } ''
      cat >report.xml <<'EOF'
      <?xml version="1.0" encoding="UTF-8" ?>
      <feedback xmlns="urn:ietf:params:xml:ns:dmarc-2.0">
        <report_metadata><org_name>receiver.test</org_name><report_id>${name}</report_id></report_metadata>
        <policy_published><domain>example.com</domain><p>reject</p></policy_published>
        <record>
          <row><source_ip>${ip}</source_ip><count>2</count>
            <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>${spf}</spf></policy_evaluated>
          </row>
          <identifiers><header_from>example.com</header_from></identifiers>
        </record>
      </feedback>
      EOF
      gzip report.xml
      {
        printf 'From: dmarc@receiver.test\nTo: ${login reports}\nDate: ${date}\nSubject: Report domain: example.com %s\n' ${name}
        printf 'MIME-Version: 1.0\nContent-Type: application/gzip; name="%s.xml.gz"\nContent-Transfer-Encoding: base64\n\n' ${name}
        base64 report.xml.gz
      } >$out
    '';
in
pkgs.testers.runNixOSTest {
  name = "o11n-mailboxes";

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
        ../../nixos/org/fail2ban.nix
        shared.mailApp
        (principal reports)
      ];
      _module.args.host = org.host.mx;
      networking.firewall.allowedTCPPorts = [ 993 ];
      # Fact: the principals' passwords, which the test logs in with.
      sops.secrets = lib.genAttrs' [ admin alice auth ] (
        entity: lib.nameValuePair "${entity.name}/mail" { inherit (entity.secrets) sopsFile; }
      );
    };

    client = {
      imports = [ resolving ];
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript =
    { nodes, ... }:
    let
      mx = nodes.mx.networking.primaryIPAddress;
      clean = report "clean" {
        ip = "192.0.2.9";
        spf = "fail";
      };
      trouble = report "trouble" {
        ip = mx;
        spf = "fail";
      };
      old = report "old" {
        ip = mx;
        spf = "pass";
        date = "Mon, 01 Jan 2024 00:00:00 +0000";
      };
      noise = pkgs.writeText "noise.eml" ''
        From: someone@receiver.test
        To: ${login reports}
        Subject: Not a report

        hello
      '';
    in
    ''
      import re

      def password(entity):
          return mx.succeed(f"cat /run/secrets/{entity}/mail").strip()

      def imap(entity, address, path, *args):
          """What curl says logged in to imaps as the principal."""
          return (
              f"curl -sS --fail -u '{address}:{password(entity)}' 'imaps://${fqdn}/{path}' "
              + " ".join(args)
          )

      def mails(address, query):
          return mx.succeed(f"doveadm search -u {address} {query} | wc -l").strip()

      start_all()
      mx.wait_for_unit("postfix.service")
      mx.wait_for_unit("dovecot.service")
      mx.wait_for_open_unix_socket("/run/rspamd/rspamd-milter.sock")

      with subtest("each domain with a mailbox has a postmaster, the admin"):
          mx.succeed("printf 'Subject: to postmaster\\n\\nhello\\n' | sendmail postmaster@example.com")
          mx.wait_until_succeeds("doveadm search -u ${login admin} header subject 'to postmaster' | grep -q .", timeout=60)

      with subtest("alice reads the admin's mailboxes as Shared.admin under her own login, and no one else does"):
          mx.wait_for_unit("mail-readers.service")
          listed = client.succeed(imap("alice", "${login alice}", "", "-X 'LIST \"\" \"*\"'"))
          assert re.search(r'"?Shared\.admin"?\r?$', listed, re.M), listed
          assert re.search(r'"?Shared\.admin\.Archive"?\r?$', listed, re.M), listed
          message = client.succeed(imap("alice", "${login alice}", "Shared.admin/;UID=1"))
          assert "to postmaster" in message, message
          # Fact: Dovecot takes a STORE of a flag the login has no right to, and leaves the flag as it was.
          client.execute(imap("alice", "${login alice}", "Shared.admin", "-X 'UID STORE 1 +FLAGS (\\Deleted)'"))
          flags = mx.succeed("doveadm fetch -u ${login admin} flags mailbox INBOX uid 1")
          assert "Deleted" not in flags, flags
          listed = client.succeed(imap("auth", "${login auth}", "", "-X 'LIST \"\" \"*\"'"))
          assert "Shared" not in listed, listed
          client.fail(imap("auth", "${login auth}", "Shared.admin/;UID=1"))

      with subtest("the admin's mailboxes grant the readers the org declares alone"):
          for mailbox in ["INBOX", "Archive"]:
              mx.succeed(f"doveadm acl set -u ${login admin} {mailbox} user=${login auth} lookup read")
          mx.succeed("systemctl restart mail-readers.service")
          for mailbox in ["INBOX", "Archive"]:
              granted = mx.succeed(f"doveadm acl get -u ${login admin} {mailbox}")
              assert "${login auth}" not in granted, granted
          client.succeed(imap("alice", "${login alice}", "Shared.admin/;UID=1"))
          client.fail(imap("auth", "${login auth}", "Shared.admin.Archive", "-X 'UID SEARCH ALL'"))

      def webmail(address, secret):
          """The status and redirect of a login to webmail, as a browser would."""
          jar = "/tmp/jar"
          client.succeed(f"rm -f {jar}")
          page = client.succeed(f"curl -sS --fail -c {jar} -b {jar} https://${fqdn}/")
          found = re.search(r'name="_token" value="([^"]+)"', page)
          assert found, page
          token = found.group(1)
          return client.succeed(
              f"curl -sS -c {jar} -b {jar} -o /dev/null -w '%{{http_code}} %{{redirect_url}}'"
              f" -d _task=login -d _action=login -d _timezone=UTC -d _url= -d _token={token}"
              f" --data-urlencode _user={address} --data-urlencode '_pass={secret}' 'https://${fqdn}/?_task=login'"
          )

      with subtest("a principal logs in to webmail with its mail password, and sees the mailboxes it reads"):
          mx.wait_for_unit("phpfpm-roundcube.service")
          mx.wait_for_unit("nginx.service")
          said = webmail("${login alice}", password("alice"))
          assert said.startswith("302 ") and "_task=mail" in said, said
          page = client.succeed("curl -sS --fail -b /tmp/jar 'https://${fqdn}/?_task=mail&_mbox=INBOX'")
          assert '"Shared.admin.Archive"' in page, page

      with subtest("failed webmail logins are counted against the client by roundcube-auth"):
          for _ in range(3):
              said = webmail("${login alice}", "wrong")
              assert said.startswith("401 "), said
          mx.wait_until_succeeds(
              "fail2ban-client status roundcube-auth | grep -q 'Total failed:\\s*3'", timeout=30
          )

      with subtest("dmarc-reports archives a clean report, flags trouble and what isn't a report, prunes the old"):
          for eml in ["${clean}", "${trouble}", "${noise}"]:
              mx.succeed(f"doveadm save -u ${login reports} -m INBOX < {eml}")
          mx.succeed("doveadm save -u ${login reports} -m Archive < ${old}")
          mx.fail("systemctl start mail-dmarc-reports.service")
          assert mails("${login reports}", "mailbox Archive subject clean") == "1"
          assert mails("${login reports}", "mailbox Archive subject old") == "0"
          assert mails("${login reports}", "mailbox INBOX flagged") == "2"
          assert mails("${login reports}", "mailbox INBOX") == "2"
          said = mx.succeed("journalctl -u mail-dmarc-reports.service")
          assert "receiver.test's report trouble on example.com: 2 from ${mx}, ${fqdn}'s, fail SPF as example.com" in said, said
          assert "holds no DMARC report: Not a report" in said, said

      with subtest("the admin hears of what's flagged, which isn't read again"):
          mx.wait_until_succeeds(
              "doveadm search -u ${login admin} header subject 'mx: mail-dmarc-reports.service failed' | grep -q .", timeout=60
          )
          body = mx.succeed("doveadm fetch -u ${login admin} text.utf8 header subject 'mx: mail-dmarc-reports.service failed'")
          assert "fail SPF as example.com" in body, body
          mx.succeed("systemctl start mail-dmarc-reports.service")
    '';
}
