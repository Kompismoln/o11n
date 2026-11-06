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
network.eth = { interface = "enp5s0", mode = "dhcp", suffix = "::fba", mac = "02:00:00:00:00:09", address4 = "192.168.1.109" }
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
- for each host behind it, the network it reaches it on, its one network with a `suffix`, which has a `mac` and an
  `address4`, or evaluation fails (`docs/parts/networks.md`):
  - a DHCP reservation of its `address4` for its `mac`, `dhcp.o11n_<host>`
  - for each port it listens on for its vpns (`docs/parts/vpns.md`), a redirect of the port on IPv4 to its `address4`,
    `firewall.o11n_<host>_<vpn>`, and a rule that lets it in on IPv6 to its suffix in whatever prefix,
    `firewall.o11n_<host>_<vpn>_6`
- with a `dmz`, a redirect of all else on IPv4 to the dmz's `address4`, `firewall.o11n_dmz`, after the others.

A host whose `behind` has no `openwrt` fails evaluation.
