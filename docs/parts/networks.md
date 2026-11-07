# Networks

A host's `network.<name>` is an interface it configures with networkd (`org/network.nix`, `nixos/org/networking.nix`),
by its `mode`: `static`, at its `address` and `address4`, or `dhcp`, as the router has it. Each of its vpns is a network
too, with no mode, which `nixos/org/wireguard.nix` configures (`docs/parts/vpns.md`).

## Suffix

A dhcp network with a `suffix` forms its IPv6 address from the prefix the router advertises and the suffix, and asks the
router for none, so that the address is the host's own for as long as the prefix lasts, whatever the router has of it:

```toml
[host.desktop]
network.eth = { interface = "enp5s0", mode = "dhcp", suffix = "::fba" }
network.wifi = { interface = "wlp4s0", mode = "dhcp" }
```

It still takes its IPv4 address by DHCP. A network that isn't dhcp, or has a suffix another network of the org has,
which could be on its link, fails evaluation.

## Router

A host with `router` is a router for the hosts whose `behind` names it (`org/router.nix`), and runs OpenWrt, the one
system o11n configures a router on (`docs/parts/openwrt.md`). A host whose `behind` has no `router`, and a `router`
without `openwrt`, fail evaluation.

```toml
[host.windsor.router]
dmz = "pelle"

[host.pelle]
behind = "windsor"
network.eth = { interface = "enp5s0", mode = "dhcp", suffix = "::fba", address4 = "192.168.1.19" }
```

Its `address4` and `prefixLength4`, by default OpenWrt's `192.168.1.1` and 24, are its address on its lan, where `o11n`
reaches it when its name doesn't answer, as a router on no vpn. From the hosts behind it, o11n derives:

- `lan`, for each of them, the network the router reaches it on: its one network with a `suffix`, which has an
  `address4` in the router's lan, or evaluation fails; the router reserves the `address4` for it by DHCP
- `forwards`, each port it listens on for its vpns (`docs/parts/vpns.md`), which the router forwards to it on IPv4 and
  lets in on IPv6 to its suffix in whatever prefix
- with a `dmz`, a host behind it or evaluation fails, all else on IPv4 forwarded to the dmz, after the forwards.

### GleSYS

A router with `glesys` keeps its WAN address in the account's DNS, as the A record of each of its `records`, by default
the `endpoint` of each host behind it that has one, as the hosts behind its NAT share its address:

```toml
[host.windsor]
keys.glesys-key = "passphrase"

[host.windsor.router]
glesys = { account = "CL12345" }
```

The API key is the host's secret `key`. As the address changes, the key has to let any address in, and needs nothing but
the domain API.
