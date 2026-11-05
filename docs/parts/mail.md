# Mail

Every principal has `principal.mail` (`org/mail.nix`), which is off until it has an inbox or sends. The org's mail
server is the host with the `mailserver` service (`nixos/services/mailserver.nix`), which takes `[mailserver]`
(`org/mailserver.nix`): its `dkimSelector`, its `endpoint`, the domain it's `mail.<endpoint>` of and the principals'
addresses are on by default, and its `admin`, `admin@<endpoint>` by default, who hears of what goes wrong.

## A principal's mail

- `mail.address`, `<name>@<endpoint>` by default, on a domain of the org's `[domain]`.
- `mail.inbox`: a mailbox at the address, on a domain with `mailbox`, and at each of `mail.aliases`, each on a domain
  with `mailbox` too.
- `mail.send`: it sends as its address.
- `mail.sendAs`: it sends as each of these too, an address or, as `@<domain>`, any address on a domain without
  `mailbox`, which no other principal has as its address, an alias or in its `sendAs`. This is how a site sends as its
  own domain while it logs in as the org's.

A principal with either has a `mail` key, a password, and an account at its address on the mail server, which logs in
with it; one that sends but has no inbox is send-only, and the server refuses mail to it. The server reads the
password's hash, `<name>/mail-sha512`, so the principal's secrets are to be granted to `host:mailserver`; a host it
sends from reads the password, so they're granted to that host too.

## Sending

Nothing sends but a principal logged in as itself, on submission: the server trusts no network to relay, smtp takes no
login, and only root and dovecot, for sieve's redirects and replies, use postfix's own `sendmail` on it. Submission
refuses an envelope sender, and rspamd a From, other than the login's address, aliases or `sendAs`, and a From of more
than one address. An address that is a principal's address or alias is that principal's alone. rspamd signs with the
DKIM key of the From's domain, which takes the envelope sender on the same domain.

On each host, `nixos/org/mail.nix` gives each principal on it that sends an msmtp account named by its id, which logs in
to `mail.<endpoint>` on 587 with the principal's password, readable by it alone, and sets the From header to its address
whatever the mail says, unless the principal has `sendAs`, when it only sets a From that is missing. There's no default
account, so mail that names none isn't sent. msmtp is the host's `sendmail` but on the mail server, where postfix is.

An app sends through its own account:

- WordPress (`nixos/apps/wordpress.nix`): PHP's `sendmail_path` is msmtp with the app's account, which, with `sendAs`,
  takes the envelope sender from the From WordPress writes, `wordpress@<site's domain>` by default.
- mobilizon (`nixos/apps/mobilizon.nix`): its mailer logs in to the server over SMTP as the app, with the password the
  container reads from a sops template bound into it, and sends from `mobilizon.from`, the app's address by default,
  which the app is to send as.

## Failures

`o11n.mail.failures` names the units on a host whose failure mails `admin`, each with the principal that tells of it,
which sends: as `OnFailure`, `mail-failure-<id>@<unit>` mails the unit's status, as the principal, from its account. A
unit that tells as a principal that doesn't send fails the host's evaluation. `state-archive@<id>:<archive>` tells as
`<id>`, and the archive service as itself (`nixos/org/state-archive.nix`, `nixos/services/archive.nix`).

## Testing

`vmTests.mail` (`tests/vm/mail.nix`) runs `tests/inventories/mail`'s mail server on `mx`, the blog's PHP pool with its
principals on `web`, and the internet on a third: DNS for the org's domains, with their SPF, DKIM and DMARC records, and
a second mail server for `elsewhere.test`, whose rspamd judges what it receives as any receiver would, in
`Authentication-Results`. A user and an app send as their addresses, the blog's PHP `mail()` and the calendar's own
login, over verified TLS, as their domains, and each passes SPF, DKIM and DMARC. It holds the server to what it refuses:
another's address or domain in the envelope or From, a From of two addresses, mail without a login or on smtp, and a
login with another principal's password. Mail as the org's domains from anywhere but the mail server fails SPF and
DMARC.

Neither WordPress nor mobilizon runs: what they write is theirs, and the server refuses what they may not send. That
o11n configures mobilizon's mailer as its principal is evaluated in `tests/inventories/mail/tests.nix`.

The records the test publishes are its own; `o11n status` checks the org's.

## Moving Kompismoln/org to it

- `[mailserver]` loses `host`, `int` and `ext`, and `[role.mailserver]` has the `mailserver` service, beside
  `dmarc-reports`, with a `[service.mailserver]` table.
- A user's `mail = true` is `principal.mail = { inbox = true, send = true }`, and its `inboxes` are
  `principal.mail.aliases`, less `alex@klimatkalendern.nu`, whose domain has no mailbox.
- `[service.dmarc-reports]` has an `id` and `principal.mail.inbox = true`; its `mail` stays as it is.
- Each app that sends, such as esse and klimatkalendern, has `principal.mail.send = true` and a `mail` key
  (`o11n secret generate app-<name> mail`), and `settings.mailServer` goes.
- esse has `principal.mail.sendAs = ["@esse.nu"]`, and klimatkalendern `["@klimatkalendern.nu"]` and a `mobilizon.from`
  on it, such as `noreply@klimatkalendern.nu`. Each domain's SPF covers `mail.kompismoln.se`, and
  `k1._domainkey.<domain>` has the key the server keeps at `/var/dkim/<domain>.k1.txt`.
- Each principal that archives sends, to tell of its failures, as does the archive service, whose secrets are then
  granted to `host:archive` and `host:mailserver`.

## Work in progress

- Nothing limits how much a principal sends, with rspamd's ratelimit or postfix's anvil.
- That a principal's secrets are granted to the hosts that read its mail password and hash isn't known at evaluation; a
  host that isn't fails as sops-nix decrypts.
- `o11n status` checks an org's own DNS for its mail (`docs/parts/o11n.md`, "Status"), but not that the DKIM key it
  finds is the server's.
