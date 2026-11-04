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

A principal with either has a `mail` key, a password, and an account at its address on the mail server, which logs in
with it; one that sends but has no inbox is send-only, and the server refuses mail to it. The server reads the
password's hash, `<name>/mail-sha512`, so the principal's secrets are to be granted to `host:mailserver`; a host it
sends from reads the password, so they're granted to that host too.

## Sending

Nothing sends but a principal logged in as itself: the server trusts no network to relay, and only root and dovecot, for
sieve's redirects and replies, use postfix's own `sendmail` on it. Submission refuses an envelope sender other than the
login's address or aliases.

On each host, `nixos/org/mail.nix` gives each principal on it that sends an msmtp account named by its id, which logs in
to `mail.<endpoint>` on 587 with the principal's password, readable by it alone, and sets the From header to its address
whatever the mail says. There's no default account, so mail that names none isn't sent. msmtp is the host's `sendmail`
but on the mail server, where postfix is.

An app sends through its own account:

- WordPress (`nixos/apps/wordpress.nix`): PHP's `sendmail_path` is msmtp with the app's account.
- mobilizon (`nixos/apps/mobilizon.nix`): its mailer logs in to the server over SMTP as the app, with the password the
  container reads from a sops template bound into it.

## Failures

`o11n.mail.failures` names the units on a host whose failure mails `admin`, each with the principal that tells of it,
which sends: as `OnFailure`, `mail-failure-<id>@<unit>` mails the unit's status, as the principal, from its account. A
unit that tells as a principal that doesn't send fails the host's evaluation. `state-archive@<id>:<archive>` tells as
`<id>`, and the archive service as itself (`nixos/org/state-archive.nix`, `nixos/services/archive.nix`).

## Moving Kompismoln/org to it

- `[mailserver]` loses `host`, `int` and `ext`, and `[role.mailserver]` has the `mailserver` service, beside
  `dmarc-reports`, with a `[service.mailserver]` table.
- A user's `mail = true` is `principal.mail = { inbox = true, send = true }`, and its `inboxes` are
  `principal.mail.aliases`, less `alex@klimatkalendern.nu`, whose domain has no mailbox.
- `[service.dmarc-reports]` has an `id` and `principal.mail.inbox = true`; its `mail` stays as it is.
- Each app that sends, such as esse and klimatkalendern, has `principal.mail.send = true` and a `mail` key
  (`o11n secret generate app-<name> mail`), and `settings.mailServer` goes.
- Each principal that archives sends, to tell of its failures, as does the archive service, whose secrets are then
  granted to `host:archive` and `host:mailserver`.

## Work in progress

- Nothing limits how much a principal sends, with rspamd's ratelimit or postfix's anvil.
- That a principal's secrets are granted to the hosts that read its mail password and hash isn't known at evaluation; a
  host that isn't fails as sops-nix decrypts.
- No test evaluates WordPress or mobilizon, so their accounts are untried, as is mobilizon's SMTP login on a running
  server.
