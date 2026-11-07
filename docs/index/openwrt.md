# `openwrt`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `host.<name>.openwrt.changes`

`org/openwrt.nix` · attribute set of string

Default: for each file of `uci`, and `system`, `dropbear`, `dhcp` and `firewall`, the commands of `uci` and of the
sections o11n derives

for each UCI file, the commands that change it: the host's `uci`, in the order of its sections' names, then o11n's,
which removes the sections it named before

### `host.<name>.openwrt.files`

`org/openwrt.nix` · attribute set of string

Default: `/etc/o11n/uci` from `changes`, `/etc/dropbear/authorized_keys` from the ssh-keys of the host's users and
service-rescue, and with a router's `glesys` its updater

the files o11n writes on the router, by path: `/etc/o11n/uci`, a script that makes all `changes` and commits them, the
ssh-keys root takes, its users' and service-rescue's, and with a router's `glesys` its updater

### `host.<name>.openwrt.imageFiles`

`org/openwrt.nix` · attribute set of string

Default: its `files` without a secret in them or `/etc/o11n/uci`, and `/etc/uci-defaults/99-o11n` with the `changes`
that have none

the files the router's image holds: its `files` but those with a secret, and instead of `/etc/o11n/uci`,
`/etc/uci-defaults/99-o11n`, which makes the changes of each file without a secret at first boot

### `host.<name>.openwrt.packages`

`org/openwrt.nix` · list of string

Default: `[ ]`

the packages the router's image has besides its profile's, or leaves out of them, as -<package>

### `host.<name>.openwrt.profile`

`org/openwrt.nix` · string

the router's OpenWrt profile, as the target's profiles.json names it

### `host.<name>.openwrt.release`

`org/openwrt.nix` · string

the OpenWrt release the router runs

### `host.<name>.openwrt.target`

`org/openwrt.nix` · string

the router's OpenWrt target, as its downloads name it

### `host.<name>.openwrt.uci`

`org/openwrt.nix` · attribute set of attribute set of attribute set of anything

Default: `{ }`

what the host changes of OpenWrt's own UCI, by file, by section, a section's name or @<type>[<index>], with a named
section's type as `_type`, or `_delete = true` to delete it: a list is set anew, and `{ secret = <key> }` is a key of
the host's, which is written in when applied; o11n adds the sections it derives, whose names start with `o11n_`
