# `secrets`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Types

### `<secrets>`

`org/secrets.nix`

had by `<entity>.secrets`

### `<secrets>.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/${handle}"`

path on the host to the age key that decrypts the entity's secrets

### `<secrets>.identityFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/${handle}.age"`

the entity's age key, encrypted to itself, its actors and the root identities

### `<secrets>.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/${handle}.yaml"`

sops file holding the entity's secrets
