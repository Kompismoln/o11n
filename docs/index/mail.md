# `mail`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

<<<<<<< signed
### `mailserver.admin`
=======
### `app.<mail>.admin`
>>>>>>> @stamp

<<<<<<< signed
`org/mailserver.nix` · string
=======
`org/apps/mail.nix` · string
>>>>>>> @stamp

<<<<<<< signed
Default: `"admin@${endpoint}"`
=======
Default: `"admin@${org.endpoint}"`
>>>>>>> @stamp

<<<<<<< signed
the address that hears of what goes wrong on the org's hosts, such as a unit that fails, a principal's address or alias
with an inbox, which is postmaster of each domain with a mailbox no principal is postmaster of
=======
the address that hears of what goes wrong, a unit that fails on a host whose principal sends through the server, a
principal's address or alias with an inbox on it, which is postmaster of each of its domains with a mailbox no principal
is postmaster of
>>>>>>> @stamp

<<<<<<< signed
### `mailserver.dkimSelector`
=======
### `app.<mail>.dkimSelector`
>>>>>>> @stamp

<<<<<<< signed
`org/mailserver.nix` · string
=======
`org/apps/mail.nix` · string
>>>>>>> @stamp

<<<<<<< signed
the selector of the mail server's dkim keys
=======
the selector of the server's dkim keys
>>>>>>> @stamp

<<<<<<< signed
### `mailserver.endpoint`
=======
### `domain.<name>.mail`
>>>>>>> @stamp

<<<<<<< signed
`org/mailserver.nix` · string
=======
`org/domain.nix` · null or impossible (empty enum)
>>>>>>> @stamp

<<<<<<< signed
Default: `"example.com"`
=======
Default: the org's app of kind mail, if it has one alone, or else `null`
>>>>>>> @stamp

<<<<<<< signed
the domain the mail server is mail.<endpoint> of, and the principals' addresses are on by default
=======
the app of kind mail that is the domain's mail server, which its principals' addresses log in to and its mail is signed
by, or null

### `domain.<name>.mailbox`

`org/domain.nix` · boolean

Default: `false`

Whether to enable mailbox.

### `domain.<name>.name`

`org/domain.nix` · string

Default: `"‹name›"`

domain name
>>>>>>> @stamp

## Types

### `<mail>`

`org/mail.nix`

had by `<principal>.mail`

### `<mail>.address`

`org/mail.nix` · string

<<<<<<< signed
Default: `<name>@<endpoint>`, the mail server's endpoint
=======
Default: `<name>@<endpoint>`, the org's endpoint
>>>>>>> @stamp

the address the principal receives at with an inbox, and sends as

### `<mail>.aliases`

`org/mail.nix` · list of string

Default: `[ ]`

the other addresses the principal's inbox receives at, as the mail server's aliases

### `<mail>.inbox`

`org/mail.nix` · boolean

Default: `false`

whether the principal has a mailbox on the mail server, at its address and its aliases

### `<mail>.readers`

`org/mail.nix` · list of string

Default: `[ ]`

the principals, by handle, each with an inbox on the same domain, that read the principal's inbox and its other
mailboxes as Shared.<name> under their own login

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
<<<<<<< signed
=======

### `<mail>.server`

`org/mail.nix` · null or string

Default: the `mail` of the domain of `address`

the app of kind mail the principal logs in to, its address's domain's `mail`, or null for an address on no domain of the
org's, or one without
>>>>>>> @stamp
