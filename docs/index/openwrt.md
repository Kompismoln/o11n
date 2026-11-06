# `openwrt`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `host.<name>.openwrt.dmz`

`org/openwrt.nix` · null or impossible (empty enum)

Default: `null`

the host behind the router that what isn't forwarded otherwise is forwarded to on IPv4, or null

### `host.<name>.openwrt.files`

`org/openwrt.nix` · attribute set of string

Default: each file of `uci`, and `system`, `dropbear` and those o11n derives sections of, rendered, and
`/etc/dropbear/authorized_keys` from the ssh-keys of the host's users

the files o11n writes on the router, by path: each `/etc/config/` file whole, the router's own sections first, in the
order of their names, and those o11n derives after, in its order

### `host.<name>.openwrt.imageFiles`

`org/openwrt.nix` · attribute set of string

Default: its `files` without a secret in them

the files the router's image holds: its `files` but those with a secret, which it has OpenWrt's own of until they're
applied

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

the router's own UCI, by file, by section name, with the section's type as `_type`: a list is a `list`, and
`{ secret = <key> }` a key of the host's, which is written in when applied; o11n adds the sections it derives, whose
names start with `o11n_`, and its options to the sections `system.system` and `dropbear.main`
