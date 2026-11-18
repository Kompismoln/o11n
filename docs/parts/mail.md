# Mail

Every principal has `principal.mail` (`org/mail.nix`), which is off until it has an inbox or sends. The org's mail
server is the host with the `mailserver` service (`nixos/services/mailserver.nix`), which takes `[mailserver]`
(`org/mailserver.nix`): its `dkimSelector`, its `endpoint`, the domain it's `mail.<endpoint>` of and the principals'
addresses are on by default, and its `admin`, `admin@<endpoint>` by default, who hears of what goes wrong, and is to be
a principal's address or alias with an inbox, or the host's evaluation fails.

## A principal's mail

- `mail.address`, `<name>@<endpoint>` by default, on a domain of the org's `[domain]`.
- `mail.inbox`: a mailbox at the address, on a domain with `mailbox`, and at each of `mail.aliases`, each on a domain
  with `mailbox` too.
- `mail.send`: it sends as its address.
- `mail.sendAs`: it sends as each of these too, an address or, as `@<domain>`, any address on a domain without
  `mailbox`, which no other principal has as its address, an alias or in its `sendAs`. This is how a site sends as its
  own domain while it logs in as the org's.
- `mail.readers`: the principals, by handle, that read its inbox and its other mailboxes (see Readers).

A principal with either has a `mail` key, a password, and an account at its address on the mail server, which logs in
with it; one that sends but has no inbox is send-only, and the server refuses mail to it. The server reads the
password's hash, `<name>/mail-sha512`, so the principal's secrets are to be granted to `host:mailserver`; a host it
sends from reads the password, so they're granted to that host too.

Each domain with `mailbox` has a postmaster, as RFC 5321 asks: where no principal has `postmaster@<domain>` as its
address or an alias, it's an alias of the admin's account.

## Readers

A principal's readers, each another principal with an inbox on the same domain, see its mailboxes under their own login,
as `Shared.<name>` and the folders under it, with Dovecot's shared namespace (`nixos/services/mailserver.nix`): they
list and read them, and mark them seen for themselves, but neither move nor delete. `mail-readers` sets the ACL of the
principal's INBOX, which its other mailboxes take theirs from, to name its readers, and takes away any other reader's,
there and in each mailbox that kept a copy: nothing but `org.toml` grants, as Dovecot's IMAP ACL commands aren't loaded.
It subscribes each reader to them, as a client such as Roundcube shows the folders its login subscribes to. Dovecot
takes the domain of `Shared.<name>` from the reader's login, which is why a reader is on the principal's domain, and its
separator, `.`, as a level of folders, which is why `<name>` has none.

## Webmail

The `webmail` service (`nixos/services/webmail.nix`), beside `mailserver` on its host, serves Roundcube at
`https://mail.<endpoint>`, with the server's certificate. A principal logs in with its address and mail password, which
Roundcube logs in to imaps and submission with, as the principal's own client would, so the server holds it to what it
may send; its readers' mailboxes are among its folders. Its database is on the host's postgresql.

## DMARC reports

The `dmarc-reports` service (`nixos/services/dmarc-reports.nix`) is a principal with an inbox, the address the org's
`rua` names, and sends, to tell of what it flags. Each hour it logs in to imaps as itself and reads each unflagged
message in its INBOX (`nixos/services/dmarc-reports.sh`): an aggregate report, as XML, zipped or gzipped, of DMARC 1 or
DMARCbis. It flags a message, which stays in INBOX, when:

- mail from an address of `mail.<endpoint>`, as it resolves there, fails DKIM or SPF as its From's domain, as when a DNS
  record has drifted from the server
- mail from elsewhere passes SPF as one of its domains, which only the server is to
- it holds no report it can read.

Anything else goes to Archive, which keeps what was sent in the org's `logRetention`, 14 days by default. If it flagged
anything, the unit fails, and its failure mails the admin (see Failures) its reasons, a line each. A flagged message is
the admin's to move or delete: unflagged, it's read again.

`o11n status`'s `dmarc` takes each domain's `rua` to name the service's address, and a domain unrelated to the address's
to authorize it (`docs/parts/o11n.md`, "Status").

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
  container reads from a sops template bound into it, and sends from its `from`, the app's address by default, which the
  app is to send as.

## Resolving

The mail server's `/etc/resolv.conf` names kresd on loopback, which validates (`nixos/services/mailserver.nix`), and
postfix, its TLS policy and rspamd read it: postfix delivers over DANE to a receiver that publishes TLSA, and the
blocklists rspamd asks see the server's own queries, not a shared resolver's, which they refuse. What looks up names
through nss still asks resolved, which knows the vpns' name servers, and kresd asks them for their namespaces too
(`docs/parts/vpns.md`). On a host that is its vpns' name server too, kresd listens there as well.

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

The internet signs `elsewhere.test` with knot, whose TLSA record names the receiver's key, and the mail server's kresd
forwards to it and trusts its key: the server's resolver answers it validated, mail to it goes over DANE, and a TLSA
record that names another key defers it.

Neither WordPress nor mobilizon runs: what they write is theirs, and the server refuses what they may not send. That
o11n configures mobilizon's mailer as its principal is evaluated in `tests/inventories/mail/tests.nix`.

The records the test publishes are its own; `o11n status` checks the org's.

`vmTests.mailboxes` (`tests/vm/mailboxes.nix`) runs `mx` with `webmail` and `dmarc-reports`, and a client. Mail to
postmaster reaches the admin. alice, the admin's reader, lists and reads its mailboxes under her own login, and can't
delete; another principal sees none, and a reader `mail-readers` doesn't know of loses what was granted it. alice logs
in to Roundcube, which lists the shared folders, and the client's failed logins count in `roundcube-auth`.
`dmarc-reports` archives a report of a spoof, flags one of the server's own mail failing SPF and a message without a
report, prunes an old report from Archive, and fails, which mails the admin its reasons; run again, it reads nothing
anew and succeeds.

## Moving Kompismoln/org to webmail and dmarc-reports

- Each domain the org sends as has `rua=mailto:dmarc-reports@kompismoln.se` in its `_dmarc`, and each but kompismoln.se
  a `<domain>._report._dmarc.kompismoln.se` TXT `v=DMARC1`, which `o11n status` checks.
- The postmaster of chatddx.com, sverigesval.org and ahbk.se is the admin's from then on.

## Work in progress

- Nothing limits how much a principal sends, with rspamd's ratelimit or postfix's anvil.
- That a principal's secrets are granted to the hosts that read its mail password and hash isn't known at evaluation; a
  host that isn't fails as sops-nix decrypts.
- `dmarc-reports` reads INBOX alone; a report rspamd took for spam waits in Junk.
- `o11n status` checks an org's own DNS for its mail (`docs/parts/o11n.md`, "Status"), but not that the DKIM key it
  finds is the server's.
