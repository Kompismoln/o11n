# `mail`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `mailserver.admin`

`org/mailserver.nix` · string

Default: `"admin@${endpoint}"`

the address that hears of what goes wrong on the org's hosts, such as a unit that fails

### `mailserver.dkimSelector`

`org/mailserver.nix` · string

the selector of the mail server's dkim keys

### `mailserver.endpoint`

`org/mailserver.nix` · string

Default: `"example.com"`

the domain the mail server is mail.<endpoint> of, and the principals' addresses are on by default

## Types

### `<mail>`

`org/mail.nix`

had by `<principal>.mail`

### `<mail>.address`

`org/mail.nix` · string

Default: `<name>@<endpoint>`, the mail server's endpoint

the address the principal receives at with an inbox, and sends as

### `<mail>.aliases`

`org/mail.nix` · list of string

Default: `[ ]`

the other addresses the principal's inbox receives at, as the mail server's aliases

### `<mail>.inbox`

`org/mail.nix` · boolean

Default: `false`

whether the principal has a mailbox on the mail server, at its address and its aliases

### `<mail>.send`

`org/mail.nix` · boolean

Default: `false`

whether the principal sends mail, as its address, by logging in to the mail server from the hosts it's on, as it does to
tell of its failures

### `<mail>.sendAs`

`org/mail.nix` · list of string

Default: `[ ]`

the other addresses the principal sends as, each an address or, as @<domain>, any address on a domain of the org's
without a mailbox
