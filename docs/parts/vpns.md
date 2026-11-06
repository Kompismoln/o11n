# Vpns

A vpn is a WireGuard network of the hosts whose `vpns` have it, `vpn.<name>` in `org.toml` (`org/vpn.nix`), each host on
it at `<prefix>::<host id>` and `<prefix4>.<host id>`, and its `topology` says how they peer
(`nixos/org/wireguard.nix`).

## Hub

A hub, the default, has a `gateway`, the one host each other peers with, and which forwards between them, so that
everything one sends another goes through the gateway. It's what access to the hosts is meant to go over: a gateway that
has `proxy` also carries the IPv6 of the others, and its `dns` resolve their names.

```toml
[vpn.wg0]
id = 0
trusted = true
gateway = "gw"
namespace = "access"
dns = ["gw"]
```

## Mesh

A mesh has no gateway: each host peers with each other, directly, so that what one sends another goes over no third.
It's for what moves a lot of data between hosts.

```toml
[vpn.wg1]
id = 1
trusted = false
topology = "mesh"
namespace = "data"
dns = []
```

- a host with an `endpoint` listens on the vpn's port there, and is dialed at it
- a host without one dials the others, and keeps each connection open, so that the NAT it's behind lets their replies in
- two hosts without an endpoint don't peer, and don't reach each other
- nothing forwards, and a mesh with a `gateway` or `proxy` fails evaluation.

The vpn's `peers` has, for each host on it, the hosts it has a tunnel with, and its `reaches` those it reaches: on a hub
each other, on a mesh its `peers`. What has to go between two hosts fails evaluation where they don't reach each other
on the vpn it would go over:

- an allotment's replica and its host, on the first vpn they share (`org/allotment.nix`, `docs/parts/allotments.md`)
- a host that archives a principal and the archive's host, on `service.archive.vpn` (`nixos/org/state-archive.nix`,
  `docs/parts/state.md`).

An endpoint is dialed at what it resolves to, so a host on IPv6 alone is reached only from those that have IPv6.
