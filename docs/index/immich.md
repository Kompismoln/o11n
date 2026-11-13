<<<<<<< signed
=======
# `immich`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `app.<name>.immich.keycloak`

`org/apps/immich.nix` · impossible (empty enum)

the keycloak app immich's users log in with

### `app.<name>.immich.realm`

`org/apps/immich.nix` · string

the keycloak realm of immich's client

### `app.<name>.immich.storages`

`org/apps/immich.nix` · attribute set of (submodule)

Default: `{ }`

the storage of each Immich user's library, by user, the Keycloak username they log in with: a box, the SMB share that is
their library; a Keycloak user without one logs in to a library they can upload nothing to

### `app.<name>.immich.storages.<name>.box`

`org/apps/immich.nix` · submodule

the SMB share that is the user's library

### `app.<name>.immich.storages.<name>.box.host`

`org/apps/immich.nix` · string

the SMB server

### `app.<name>.immich.storages.<name>.box.key`

`org/apps/immich.nix` · string

the entity, by its handle, whose smb-password it logs in with, which has to grant the app's hosts

### `app.<name>.immich.storages.<name>.box.login`

`org/apps/immich.nix` · string

the user it logs in as

### `app.<name>.immich.storages.<name>.box.share`

`org/apps/immich.nix` · string

the share on the server, and the path in it, as mount.cifs takes them
>>>>>>> @stamp
