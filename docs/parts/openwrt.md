# OpenWrt

A host with `openwrt` runs OpenWrt (`org/openwrt.nix`), and no NixOS, as its `nixos` is false. Its `release`, `target`,
`profile` and `packages` say what its image is, and its `uci` what it changes of OpenWrt's own configuration. o11n adds
what it derives, from the host and, for a `router`, from what `docs/parts/networks.md` says of it, into `openwrt.files`,
the files written on it, which `openwrtConfigurations.<host>.files` has as a tree (`lib/default.nix`).

```toml
[host.windsor]
id = 13
roles = []
vpns = []
system = "mips-linux"
users = ["admin"]
keys.wifi-key = "passphrase"

[host.windsor.router]
dmz = "pelle"

[host.windsor.openwrt]
release = "25.12.6"
target = "ath79/generic"
profile = "netgear_wndr3700"
packages = ["-ppp", "-ppp-mod-pppoe"]

[host.windsor.openwrt.uci.wireless.radio0]
_type = "wifi-device"
disabled = 0

[host.windsor.openwrt.uci.wireless.default_radio0]
_type = "wifi-iface"
ssid = "windsor"
encryption = "psk2"
key = { secret = "wifi-key" }
```

## Changes

`uci.<file>.<section>` changes a section of `/etc/config/<file>`, and leaves the rest of what OpenWrt has there as it
is. A section is its name, with its type as `_type`, which creates it or keeps the options it has, or
`@<type>[<index>]`, one the router has, as OpenWrt leaves many unnamed, without `_type`. Each option is set, a list
anew, and `{ secret = <key> }` is a key the host has, written as `@o11n-secret:<key>@`, for its value to take its place
when the changes are applied. `_delete = true`, alone, deletes the section. A section or option left out of `uci` keeps
what it has on the router, until the router is flashed.

`openwrt.changes.<file>` is a file's changes as `uci` commands, the sections of `uci` in the order of their names, then
o11n's: of `system`, `dropbear`, `dhcp` and `firewall`, whether `uci` has them or not. o11n names the sections it
derives `o11n_<...>`, removes those it named before, and adds them anew after the router's own, in its order, as fw4
matches redirects in order. One of `uci` named so, a section that is neither, a named one without `_type` and an index
with it fail evaluation.

o11n derives:

- `@system[0]`'s `hostname`, the host's name, and `@dropbear[0]`'s login by key alone, over what `uci` sets of them
- `/etc/dropbear/authorized_keys`, the ssh-keys of the host's `users` and service-rescue's, as root on a NixOS host
  takes
- for a `router`, from its `address4`, `prefixLength4`, `lan`, `forwards` and `dmz`:
  - `network.lan`'s address, `ipaddr`
  - a DHCP reservation, `dhcp.o11n_<host>`, for the host's `mac`, or without one for the name it asks with, which
    networkd sends as the host's
  - for each forward, a redirect on IPv4, `firewall.o11n_<host>_<vpn>`, and a rule on IPv6,
    `firewall.o11n_<host>_<vpn>_6`
  - with a `dmz`, its redirect, `firewall.o11n_dmz`, after the others.

`/etc/o11n/uci` is a script that makes all of the changes, stops at the first that fails, and commits them.

## Image

`openwrtConfigurations.<host>.image` is the router's sysupgrade image, built by OpenWrt's ImageBuilder as the flake
input `openwrt-imagebuilder` wraps it (`lib/default.nix`), with the profile's packages and `packages`, and
`openwrt.imageFiles`: its `files` but those with a secret, and instead of `/etc/o11n/uci`, `/etc/uci-defaults/99-o11n`,
which OpenWrt runs at first boot, with the changes of each file that has no secret. A file with one stays OpenWrt's own
until the changes are applied, as a `wireless` whose radios are off. The input reads the release's package index from
downloads.openwrt.org as the image is evaluated, so only a machine that reaches it evaluates the image, and no check
does. It holds the hashes of each series' latest release alone, so `release` is that of the input's revision.

`o11n openwrt image <host>` builds it and prints it, and `o11n openwrt flash <host> <image>` copies it to the router as
root, as `o11n openwrt apply` logs in, has `sysupgrade -T` check it there, and flashes it with `sysupgrade -n`, which
keeps nothing of what the router had (`crates/o11n/src/openwrt.rs`). The router comes up with a new ssh-key, which
`o11n host pull-ssh-key host-<host>` takes, and without the changes with secrets, which `o11n openwrt apply` makes.

## Apply

`o11n openwrt apply <host>` writes the router's `files`, each secret's marker replaced with the host's secret, as root
with service-rescue's ssh-key, and the operator's, if it has one, or, for an operator who can't act as service-rescue,
the operator's alone, as on a router that doesn't take service-rescue's yet. It reaches the router as `o11n` reaches any
host, by `O11N_ROUTES` or its name in a namespace, or else at a router's `address4`, and runs `/etc/o11n/uci`. A file
with a secret, and `authorized_keys`, are root's alone. It keeps what it replaces, and `/etc/config`, in
`/tmp/o11n-rollback`, puts that back at once if a change fails, with `uci`'s own error, and otherwise runs
`reload_config`, which restarts what the changes touched. Unless `o11n` logs in again within 90 seconds, the router puts
back what it kept and reloads that, so that changes that lock `o11n` out undo themselves.

## GleSYS

For a router's `glesys` (`docs/parts/networks.md`), o11n derives `/etc/o11n/glesys`, which lists the records of each
domain of `records` once, with the API key, and updates the A record that isn't the WAN address, and says so, or why it
couldn't, to the router's log as `o11n-glesys`. It runs once the WAN is up, by `/etc/hotplug.d/iface/90-o11n-glesys`,
and every 15 minutes, by `/etc/crontabs/root`, which `o11n openwrt apply` has cron read anew. It sends the key as a
Basic `Authorization` header, which `ucode` encodes. The image leaves the script out, as it holds the key, until it's
applied.
