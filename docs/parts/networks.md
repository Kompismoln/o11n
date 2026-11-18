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
id = 9
behind = "windsor"
network.eth = { interface = "enp5s0", mode = "dhcp" }
network.wifi = { interface = "wlp4s0", mode = "dhcp", metric = 2048 }
```

Its `address4` and `prefixLength4`, by default OpenWrt's `192.168.1.1` and 24, are its address on its lan, where `o11n`
reaches it when its name doesn't answer, as a router on no vpn.

A host behind it is on its lan on its network with `lan`, by default its dhcp network with the lowest metric where one
network has it (`org/network.nix`): pelle's eth above. That network's `address4` and `suffix` are by default 10 past the
host's id, `192.168.1.19` and `::19` for pelle, clear of the router's address and of OpenWrt's DHCP pool; either can be
set as any other. From the hosts behind it, o11n derives:

- `lan`, for each of them, its network with `lan`, whose `address4` is in the router's lan, neither the router's nor its
  first or last, or evaluation fails; the router reserves the `address4` for it by DHCP
- `forwards`, each port it listens on for its vpns (`docs/parts/vpns.md`), which the router forwards to it on IPv4 and
  lets in on IPv6 to its suffix in whatever prefix
- `exposes`, the same for the web, ports 80 and 443, to each host behind it that serves the web, as an app of a kind on
  an app-scheduler does, or a nix-remote or remote-builder-relay; on IPv4 to `web` alone, by default the one host that
  does, as one address has each port once, or evaluation fails while two do; and for a torrent-server's `peerPort`
- with a `dmz`, a host behind it or evaluation fails, all else on IPv4 forwarded to the dmz, after the forwards.

### GleSYS

A router with `glesys` keeps its WAN address in the account's DNS, as the A record of each of its `records`, by default
the `endpoint` of each host behind it that has one, as the hosts behind its NAT share its address. On IPv6, where each
has its own, it keeps the AAAA record of each of its `records6`, by default each of `records` that is a host's
`endpoint`, as the prefix it delegates to its lan with the host's `suffix`; as the prefix changes with the ISP's lease,
so do the records:

```toml
[host.windsor]
keys.glesys-key = "passphrase"

[host.windsor.router]
glesys = { account = "CL12345" }
```

The API key is the host's secret `key`. As the address changes, the key has to let any address in, and needs nothing but
the domain API. The router updates the records it finds and logs those it doesn't: an AAAA record is created by hand
once, as an A record is.
