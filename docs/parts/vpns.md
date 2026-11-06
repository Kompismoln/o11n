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
- a host without one dials the others, and keeps each connection open, so that the NAT it's behind lets their replies
  in; a pair of hosts without an endpoint can't reach each other, and fails evaluation on each of them that is a NixOS
  host
- nothing forwards, and a mesh with a `gateway` or `proxy` fails evaluation.

An endpoint is dialed at what it resolves to, so a host on IPv6 alone is reached only from those that have IPv6.
