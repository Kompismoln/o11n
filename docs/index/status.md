<<<<<<< signed
=======
# `status`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Types

### `<status>`

`org/apps/status.nix`

had by `app.<status>`, `app.<status>.announcements.*`

### `<status>.announcements`

`org/apps/status.nix` · list of (submodule)

Default: `[ ]`

what the page announces, newest first, as Gatus's announcements: an incident, maintenance, or what's back to normal

### `<status>.groups`

`org/apps/status.nix` · attribute set of list of impossible (empty enum)

Default: `{ }`

the apps the page watches at their url, by the group it shows them in

### `<status>.interval`

`org/apps/status.nix` · string

Default: `"2m"`

how often each check runs, as Gatus takes it

### `<status>.mail`

`org/apps/status.nix` · null or string

Default: `null`

the group the page shows the mail server's ports in, mail.<endpoint>'s submission, imaps and smtp, or null for none

### `<status>.message`

`org/apps/status.nix` · string

what the page says

### `<status>.portal`

`org/apps/status.nix` · null or impossible (empty enum)

Default: `null`

the portal the page links back to, with its logo, and whose footer links to the page, or null

### `<status>.timestamp`

`org/apps/status.nix` · string

when, in RFC 3339

### `<status>.type`

`org/apps/status.nix` · one of "outage", "warning", "information", "operational", "none"

what kind of announcement it is
>>>>>>> @stamp
