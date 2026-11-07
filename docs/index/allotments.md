# `allotments`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `allotment.<name>.entity`

`org/allotment.nix` · string

Default: the `<handle>` of its name

the handle of the principal the allotment is for, as its name has it before the @

### `allotment.<name>.host`

`org/allotment.nix` · string

Default: the `<host>` of its name

the host the allotment is on, as its name has it after the @

### `allotment.<name>.id`

`org/allotment.nix` · string

Default: `"${entity}.${host}"`

the allotment's name, its @ a dot, as units and keys can have it

### `allotment.<name>.key`

`org/allotment.nix` · string

Default: `"syncthing-${id}"`

the key each host that syncs the allotment, the one that has it and each replica, has of its own

### `allotment.<name>.networks`

`org/allotment.nix` · lazy attribute set of raw value

Default: for each replica, the host's network on `vpn`, or on the first vpn the replica shares with it

for each replica, the host's network it syncs with the host on

### `allotment.<name>.path`

`org/allotment.nix` · string

Default: `"/srv/allotments/${entity}"`

where the allotment is on its host

### `allotment.<name>.port`

`org/allotment.nix` · 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: 22000 plus the principal's `uid`

the port the allotment's host listens on for its replicas

### `allotment.<name>.replicas`

`org/allotment.nix` · list of impossible (empty enum)

Default: `[ ]`

the hosts that keep a replica of the allotment for its principal, which has to be on each, synced with it over `vpn`, on
which they reach each other

### `allotment.<name>.size`

`org/allotment.nix` · string matching the pattern [1-9][0-9]*[KMGTP]

the most the allotment holds, as a ZFS size, of what's in it and not of its snapshots

### `allotment.<name>.vpn`

`org/allotment.nix` · null or impossible (empty enum)

Default: `null`

the vpn the allotment syncs over, which its host and each replica are on, or null for the first vpn each replica shares
with the host
