# `state`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Types

### `<state>`

`org/state.nix`

had by `<principal>.state`

### `<state>.archives`

`org/state.nix` · (attribute set of (submodule)) or (list of impossible (empty enum)) convertible to it

Default: `{ }`

the hosts with the archive service that archive the principal's home, as a list or each with a schedule and a prune;
only an archive with a schedule has a timer

### `<state>.archives.<name>.prune`

`org/state.nix` · submodule

Default: `{ }`

what of the principal's archive on the host `o11n state prune` keeps, as restic forget's policy; with none, everything

### `<state>.archives.<name>.prune.keep-daily`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-daily: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.prune.keep-hourly`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-hourly: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.prune.keep-last`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-last: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.prune.keep-monthly`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-monthly: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.prune.keep-tag`

`org/state.nix` · list of string

Default: `[ ]`

restic forget's --keep-tag: the tags whose snapshots to keep

### `<state>.archives.<name>.prune.keep-weekly`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-weekly: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.prune.keep-within`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-within-daily`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within-daily: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-within-hourly`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within-hourly: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-within-monthly`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within-monthly: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-within-weekly`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within-weekly: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-within-yearly`

`org/state.nix` · null or string matching the pattern ([0-9]+[ymdh])+

Default: `null`

restic forget's --keep-within-yearly: a duration such as 1y2m3d4h, before the latest snapshot

### `<state>.archives.<name>.prune.keep-yearly`

`org/state.nix` · null or integer between -1 and 2147483647 (both inclusive)

Default: `null`

restic forget's --keep-yearly: the number of snapshots to keep, -1 for all

### `<state>.archives.<name>.schedule`

`org/state.nix` · null or string

Default: `null`

when to archive, as a systemd calendar event, or null to archive only when asked

### `<state>.preserve`

`org/state.nix` · boolean

Default: `true`

whether the principal's home outlasts a boot on a host whose root doesn't, which archiving it takes
