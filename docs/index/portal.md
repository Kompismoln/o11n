# `portal`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `app.<portal>.accent`

`org/apps/portal.nix` · string

Default: `"#2563eb"`

the site's accent color, as CSS takes it

### `app.<portal>.accentHeader`

`org/apps/portal.nix` · boolean

Default: `false`

whether the header is the accent color in light mode, with white on it, and its logo as dark mode has it

### `app.<portal>.content`

`org/apps/portal.nix` · path of a file in the org

Default: `"site"`

the directory in the org of the site's markdown, as Zola's content directory, in the default language and each other's
`<name>.<language>.md`

### `app.<portal>.invites`

`org/apps/portal.nix` · null or string

Default: `null`

the address the site's form mails a visitor's request for an invite to, or null for no form

### `app.<portal>.keycloak`

`org/apps/portal.nix` · null or impossible (empty enum)

Default: `null`

the keycloak app the site's visitors log in with, or null for no login

### `app.<portal>.languages`

`org/apps/portal.nix` · non-empty (list of (one of "sv", "en"))

Default:

```nix
[
  "sv"
  "en"
]
```

the site's languages, the default first

### `app.<portal>.logo`

`org/apps/portal.nix` · null or (path of a file in the org)

Default: `null`

the logo the site shows, by the path of a file in the org, or null

### `app.<portal>.logoHeight`

`org/apps/portal.nix` · string

Default: `"2rem"`

the height of the logo in the site's header, as CSS takes it

### `app.<portal>.realm`

`org/apps/portal.nix` · string

Default: `""`

the keycloak realm of the site's client

### `app.<portal>.services`

`org/apps/portal.nix` · list of impossible (empty enum)

Default: `[ ]`

the apps the site lists, in its order, each described in the content's front matter, under extra.services.<app>
