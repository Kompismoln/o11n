# `drive`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `app.<drive>.keycloak`

`org/apps/drive.nix` · null or impossible (empty enum)

Default: `null`

the keycloak app Nextcloud's users log in with, or null for Nextcloud's own logins alone

### `app.<drive>.realm`

`org/apps/drive.nix` · string

Default: `""`

the keycloak realm of Nextcloud's client

### `app.<drive>.storages`

`org/apps/drive.nix` · attribute set of attribute set of (submodule)

Default: `{ }`

the storages of each Nextcloud user, by user, then by name: each a folder of its name in their root, or, without one, in
a folder no one can write in

### `app.<drive>.storages.<name>.<name>.allotment`

`org/apps/drive.nix` · null or impossible (empty enum)

Default: `null`

the allotment, as <handle>@<host>, the storage reaches over SFTP, whose `sftp` has to have the app, or null

### `app.<drive>.storages.<name>.<name>.bind`

`org/apps/drive.nix` · null or string

Default: `null`

the directory on the app's hosts the storage is of, which nextcloud's user can write in, or null

### `app.<drive>.storages.<name>.<name>.library`

`org/apps/drive.nix` · null or impossible (empty enum)

Default: `null`

the photos app whose library of the user the storage is, read-only, from the root's share, or null

### `app.<drive>.storages.<name>.<name>.photos`

`org/apps/drive.nix` · null or impossible (empty enum)

Default: `null`

the photos app the storage is a drop folder of, which takes what's put there into the user's library there, deleting it,
or null

### `app.<drive>.storages.<name>.<name>.sftp`

`org/apps/drive.nix` · null or (submodule)

Default: `null`

the SFTP server the storage reaches, or null

### `app.<drive>.storages.<name>.<name>.sftp.host`

`org/apps/drive.nix` · string

the server, as Nextcloud takes it: a name, or an IPv6 address in brackets

### `app.<drive>.storages.<name>.<name>.sftp.key`

`org/apps/drive.nix` · null or string

Default: `null`

the entity, by its handle, whose sftp-key the mount logs in with, which has to grant the app's hosts, or null for the
app's

### `app.<drive>.storages.<name>.<name>.sftp.login`

`org/apps/drive.nix` · string

the user it logs in as

### `app.<drive>.storages.<name>.<name>.sftp.root`

`org/apps/drive.nix` · string

Default: `"/"`

the directory on the server the mount is of

### `app.<drive>.storages.<name>.<name>.sharing`

`org/apps/drive.nix` · boolean

Default: `false`

whether the user can share from the storage, Nextcloud's enable_sharing
