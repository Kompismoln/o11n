# `keycloak`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `app.<name>.keycloak.realms`

`org/apps/keycloak.nix` · attribute set of (submodule)

Default: `{ }`

the realms whose settings o11n keeps, by name; Keycloak keeps the rest of a realm, its users included

### `app.<name>.keycloak.realms.<name>.displayName`

`org/apps/keycloak.nix` · string

Default: the realm's name

the realm's name as its pages and mail show it
