# OpenWrt

A host with `openwrt` is a router that runs OpenWrt (`org/openwrt.nix`), and no NixOS, as its `nixos` is false. Its
`release`, `target`, `profile` and `packages` say what its image is, its `uci` its own configuration, and o11n derives
the rest from the hosts `behind` it (`org/host.nix`), into `openwrt.files`, the files written on it, which
`openwrtConfigurations.<host>.files` has as a tree (`lib/default.nix`).

```toml
[host.windsor]
id = 13
roles = []
vpns = []
system = "mips-linux"
users = ["admin"]
keys.wifi-key = "passphrase"

[host.windsor.openwrt]
release = "25.12.6"
target = "ath79/generic"
profile = "netgear_wndr3700"
packages = ["-ppp", "-ppp-mod-pppoe"]
dmz = "stationary"

[host.windsor.openwrt.uci.wireless.default_radio0]
_type = "wifi-iface"
device = "radio0"
network = "lan"
mode = "ap"
ssid = "windsor"
encryption = "psk2"
key = { secret = "wifi-key" }

[host.pelle]
behind = "windsor"
network.eth = { interface = "enp5s0", mode = "dhcp", suffix = "::fba", address4 = "192.168.1.19" }
```

## Files

Each `/etc/config/` file is written whole: the sections of `uci`, in the order of their names, and after them those o11n
derives, in its order, so that a file `uci` leaves out holds only those. A section is `uci.<file>.<name>`, its type
`_type`, a list a `list`, and `{ secret = <key> }` a key the host has, written as `@o11n-secret:<key>@`, for its value
to take its place when the files are applied. o11n names the sections it derives `o11n_<...>`, and one of `uci` named so
fails evaluation.

o11n derives:

- `system.system`'s `hostname`, the host's name, and `dropbear.main`'s login by key alone, over the options `uci` gives
  them
- `/etc/dropbear/authorized_keys`, the ssh-keys of the host's `users`
- for each host behind it, the network it reaches it on, its one network with a `suffix`, which has an `address4`, or
  evaluation fails (`docs/parts/networks.md`):
  - a DHCP reservation of its `address4`, `dhcp.o11n_<host>`, for its `mac`, or without one for the name it asks with,
    which networkd sends as the host's
  - for each port it listens on for its vpns (`docs/parts/vpns.md`), a redirect of the port on IPv4 to its `address4`,
    `firewall.o11n_<host>_<vpn>`, and a rule that lets it in on IPv6 to its suffix in whatever prefix,
    `firewall.o11n_<host>_<vpn>_6`
- with a `dmz`, a redirect of all else on IPv4 to the dmz's `address4`, `firewall.o11n_dmz`, after the others.

A host whose `behind` has no `openwrt` fails evaluation.

## Image

`openwrtConfigurations.<host>.image` is the router's sysupgrade image, built by OpenWrt's ImageBuilder as the flake
input `openwrt-imagebuilder` wraps it (`lib/default.nix`), with the profile's packages and `packages`, and
`openwrt.imageFiles`: its `files` but those with a secret, which the image leaves to OpenWrt's own until they're
applied, as a `wireless` whose radios are off. The input reads the release's package index from downloads.openwrt.org as
the image is evaluated, so only a machine that reaches it evaluates the image, and no check does. It holds the hashes of
each series' latest release alone, so `release` is that of the input's revision.

`o11n openwrt image <host>` builds it and prints it, and `o11n openwrt flash <host> <image>` copies it to the router as
root with the operator's ssh-key, has `sysupgrade -T` check it there, and flashes it with `sysupgrade -n`, which keeps
nothing of what the router had (`crates/o11n/src/openwrt.rs`). The router comes up with a new ssh-key, which
`o11n host pull-ssh-key host-<host>` takes, and without the files with secrets, which `o11n openwrt apply` writes.

## Apply

`o11n openwrt apply <host>` writes the router's `files`, each secret's marker replaced with the host's secret, as root
with the operator's ssh-key, reached as `o11n` reaches any host, by `O11N_ROUTES` or its name in a namespace. A file
with a secret, and `authorized_keys`, are root's alone. It keeps what it replaces in `/tmp/o11n-rollback`, and runs
`reload_config`, which restarts what the files changed. Unless `o11n` logs in again within 90 seconds, the router puts
back what it kept and reloads that, so that files that lock `o11n` out undo themselves.
