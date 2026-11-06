{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs) org;
  inherit (org.app) blog calendar;
  inherit (org.mailserver) dkimSelector endpoint;
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared)
    fqdn
    elsewhere
    receiver
    tls
    inventorySecrets
    principal
    ;

  # Fact: the internet answers DNS for the org's domains as their zones would, and receives elsewhere.test's mail.
  resolving =
    { nodes, ... }:
    {
      networking.nameservers = lib.mkForce [ nodes.internet.networking.primaryIPAddress ];
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
      environment.systemPackages = [ pkgs.swaks ];
    };

  # Accommodating for the test's network, whose internet answers DNS.
  mailserver =
    { nodes, ... }:
    {
      imports = [ shared.mailserver ];
      services.rspamd.locals."options.inc".text = ''
        dns {
          nameservers = ["${nodes.internet.networking.primaryIPAddress}"];
          timeout = 1s;
          retransmits = 0;
        }
      '';
    };

  # Fact: the blog's kind without WordPress, whose own mail is its business: its PHP pool mails through
  # sendmail_path as WordPress does, From wordpress@<site's domain>.
  wordpress =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    import ../../nixos/apps/wordpress.nix {
      app = blog;
      inherit config lib pkgs;
    };
  wpHome = "${blog.principal.home}/wordpress";
  mailPhp = pkgs.writeText "mail.php" ''
    <?php
    echo mail('carol@${elsewhere}', 'from php', "hello\n", 'From: WordPress <wordpress@example.org>') ? 'sent' : 'failed';
  '';
in
pkgs.testers.runNixOSTest {
  name = "o11n-mail";

  imports = [ ./timeout.nix ];
  globalTimeout = 600;

  node.specialArgs = { inherit org o11nInputs; };

  nodes = {
    mx = {
      imports = [
        inventorySecrets
        resolving
        mailserver
        ../../nixos/preserve.nix
        ../../nixos/services/mailserver.nix
      ];
      _module.args.host = org.host.mx;
      networking.firewall.allowedTCPPorts = [ 587 ];
    };

    web = {
      imports = [
        inventorySecrets
        resolving
        ../../nixos/preserve.nix
        ../../nixos/org/mail.nix
        wordpress
        (principal org.user.alice)
        (principal blog)
        (principal calendar)
        (principal org.app.auth)
      ];
      _module.args.host = org.host.web;
      services.nginx.enable = true;
      # Accommodating for the test's network, which has no wg0: the principals bind to their loopback addresses as
      # nixos/org/networking.nix routes them.
      networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
    };

    internet =
      { nodes, ... }:
      let
        mx = nodes.mx.networking.primaryIPAddress;
        internet = nodes.internet.networking.primaryIPAddress;
        domains = lib.attrNames org.domain;
      in
      {
        imports = [
          o11nInputs.nixos-mailserver.nixosModules.default
          mailserver
        ];
        security.pki.certificateFiles = [ "${tls}/ca.crt" ];
        environment.systemPackages = [ pkgs.swaks ];
        networking.firewall.allowedTCPPorts = [ 53 ];
        networking.firewall.allowedUDPPorts = [ 53 ];

        mailserver = {
          enable = true;
          stateVersion = 3;
          fqdn = receiver;
          domains = [ elsewhere ];
          accounts."carol@${elsewhere}" = {
            catchAll = [ elsewhere ];
            hashedPasswordFile = pkgs.runCommand "carol-sha512" { nativeBuildInputs = [ pkgs.mkpasswd ]; } ''
              mkpasswd -m sha-512 carol > $out
            '';
          };
        };
        services.rspamd.locals."greylist.conf".text = "enabled = false;";

        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = true;
          settings = {
            no-resolv = true;
            conf-dir = "/run/dnsmasq.d";
            host-record = [
              "${fqdn},${mx}"
              "${receiver},${internet}"
            ];
            mx-host = [ "${elsewhere},${receiver},10" ] ++ map (domain: "${domain},${fqdn},10") domains;
            txt-record =
              map (domain: "${domain},\"v=spf1 ip4:${mx} -all\"") domains
              ++ map (domain: "_dmarc.${domain},\"v=DMARC1; p=reject\"") domains;
          };
        };
        systemd.tmpfiles.rules = [ "d /run/dnsmasq.d 0755 root root - -" ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import re

      def received(subject):
          """The headers of the one message elsewhere.test received with subject."""
          user, query = "-u carol@${elsewhere}", f"header subject '{subject}'"
          retry(lambda _: len(internet.succeed(f"doveadm search {user} {query}").split("\n")) == 2, timeout_seconds=120)
          return internet.succeed(f"doveadm fetch {user} hdr {query}").removeprefix("hdr:\n")

      def authenticated(headers, sender):
          """That the message is from sender, envelope and From, and passes SPF, DKIM and DMARC as its domain."""
          domain = sender.rpartition("@")[2]
          results = re.search(r"^Authentication-Results: .*?(?=^\S)", headers, re.M | re.S)
          assert results, headers
          results = " ".join(results.group(0).split())
          assert re.search(rf"^Return-Path: <{re.escape(sender)}>$", headers, re.M), headers
          assert re.search(rf"^From: (.*<)?{re.escape(sender)}>?$", headers, re.M), headers
          assert f"dkim=pass header.d={domain}" in results, results
          assert "spf=pass" in results and f"smtp.mailfrom={sender}" in results, results
          assert "dmarc=pass" in results and f"header.from={domain}" in results, results

      def password(name):
          return web.succeed(f"cat /run/secrets/{name}/mail").strip()

      def swaks(server, sender, rcpt, subject, *args):
          return (
              f"swaks --suppress-data --server {server} --from {sender} --to {rcpt}"
              f" --header 'Subject: {subject}' {' '.join(args)}"
          )

      def submit(login, sender, header_from=None, port=587, subject="submitted"):
          args = ["--tls"]
          if login:
              args.append(f"--auth-user {login}@${endpoint} --auth-password '{password(login)}'")
          if header_from:
              args.append(f"--header 'From: {header_from}'")
          return swaks(f"${fqdn}:{port}", sender, "carol@${elsewhere}", subject, *args)

      start_all()
      internet.wait_for_unit("dnsmasq.service")
      for machine in (mx, internet):
          machine.wait_for_unit("postfix.service")
          machine.wait_for_unit("dovecot.service")
          machine.wait_for_open_unix_socket("/run/rspamd/rspamd-milter.sock")

      with subtest("each of the org's domains publishes the mail server's dkim key"):
          records = []
          for domain in ${builtins.toJSON (lib.attrNames org.domain)}:
              zone = mx.succeed(f"cat ${nodes.mx.mailserver.dkim.keyDirectory}/{domain}.${dkimSelector}.txt")
              key = "".join(re.findall(r'"([^"]*)"', zone))
              assert key.startswith("v=DKIM1"), zone
              chunks = ",".join(f'"{key[i:i + 200]}"' for i in range(0, len(key), 200))
              records.append(f"txt-record=${dkimSelector}._domainkey.{domain},{chunks}")
          internet.succeed(f"printf '%s\\n' {' '.join(repr(r) for r in records)} > /run/dnsmasq.d/dkim.conf")
          internet.succeed("systemctl restart dnsmasq.service")
          internet.wait_for_unit("dnsmasq.service")

      with subtest("a principal without sendAs sends as its address, whatever the mail says"):
          web.succeed(
              "printf 'From: blog@${endpoint}\\nTo: carol@${elsewhere}\\nSubject: as alice\\n\\nhello\\n'"
              " | sudo -u alice msmtp -C /etc/msmtprc -a user-alice carol@${elsewhere}"
          )
          authenticated(received("as alice"), "alice@${endpoint}")

      with subtest("an app sends as its own address, the org's internal identity"):
          web.succeed(
              "printf 'To: carol@${elsewhere}\\nSubject: as blog\\n\\nhello\\n'"
              " | sudo -u blog msmtp -C /etc/msmtprc -a app-blog carol@${elsewhere}"
          )
          authenticated(received("as blog"), "blog@${endpoint}")

      with subtest("the blog's PHP mails as its own domain, which SPF, DKIM and DMARC pass"):
          web.wait_for_unit("phpfpm-blog.service")
          web.wait_for_unit("nginx.service")
          web.succeed("install -o blog -g blog -m 0640 ${mailPhp} ${wpHome}/mail.php")
          sent = web.succeed("curl -sf --resolve ${blog.endpoint}:80:127.0.0.1 http://${blog.endpoint}/mail.php")
          assert sent == "sent", sent
          authenticated(received("from php"), "wordpress@example.org")

      with subtest("the calendar logs in over verified TLS and sends as its own domain"):
          web.succeed(
              submit("calendar", "noreply@example.net", header_from="Calendar <noreply@example.net>", subject="from calendar")
              + " --tls-verify --tls-ca-path /etc/ssl/certs/ca-certificates.crt"
          )
          authenticated(received("from calendar"), "noreply@example.net")

      with subtest("an app can't send as another's address or domain, in the envelope or in From"):
          web.fail(submit("blog", "alice@${endpoint}"))
          web.fail(submit("blog", "noreply@example.net"))
          web.fail(submit("calendar", "wordpress@example.org"))
          web.fail(submit("blog", "blog@${endpoint}", header_from="alice@${endpoint}"))
          web.fail(submit("blog", "news@example.org", header_from="noreply@example.net"))
          web.fail(submit("blog", "news@example.org", header_from="news@example.org, alice@${endpoint}"))
          web.succeed(submit("blog", "news@example.org", header_from="news@example.org", subject="as news"))
          authenticated(received("as news"), "news@example.org")

      with subtest("nothing sends but a login on submission"):
          web.fail(submit(None, "blog@${endpoint}"))
          web.fail(submit(None, "blog@${endpoint}", port=25))
          web.fail(submit("blog", "blog@${endpoint}", port=25))
          internet.fail(swaks("${fqdn}:25", "carol@${elsewhere}", "dave@${elsewhere}", "relayed"))

      with subtest("a principal reads its own mail password alone"):
          web.fail("sudo -u alice cat /run/secrets/blog/mail")
          web.fail(
              "printf 'Subject: as blog\\n\\nhello\\n'"
              " | sudo -u alice msmtp -C /etc/msmtprc -a app-blog carol@${elsewhere}"
          )

      with subtest("mail as the org's domains from anywhere but the mail server fails SPF and DMARC"):
          web.succeed(
              swaks("${receiver}:25", "news@example.org", "erin@${elsewhere}", "forged", "--header 'From: news@example.org'")
          )
          headers = received("forged")
          assert re.search(r"\bspf=fail\b", headers), headers
          assert re.search(r"\bdmarc=fail\b", headers), headers
    '';
}
