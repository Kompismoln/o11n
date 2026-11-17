# Vpns

A vpn is a WireGuard network of the hosts whose `vpns` have it, `vpn.<name>` in `org.toml` (`org/vpn.nix`), each host on
it at `<prefix>::<host id>` and `<prefix4>.<host id>`, and its `topology` says how they peer
(`nixos/org/wireguard.nix`).

## Hub

A hub, the default, has a `gateway`, the one host each other peers with, at the vpn's `port`, by default `51820 + id`,
and which forwards between them, so that everything one sends another goes through the gateway. It's what access to the
hosts is meant to go over: a gateway that has `proxy` also carries the IPv6 of the others, and its `dns` resolve their
names.

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

- a host with an `endpoint` listens there, and is dialed at it, on a port of its own: the vpn's `port`, by default
  `52000 + 100 * id`, plus its id, so that hosts behind one NAT, which share its IPv4 address, can each have theirs
  forwarded
- a host without one dials the others, and keeps each connection open, so that the NAT it's behind lets their replies in
- two hosts without an endpoint don't peer, and don't reach each other
- nothing forwards, and a mesh with a `gateway` or `proxy` fails evaluation.

On a vpn without `dns`, as a mesh, each host has in `/etc/hosts` the names on it of itself and of those it reaches,
their services' included (`nixos/org/wireguard.nix`).

A host that would listen on one port for two of its vpns fails evaluation.

The vpn's `peers` has, for each host on it, the hosts it has a tunnel with, and its `reaches` those it reaches: on a hub
each other, on a mesh its `peers`. What has to go between two hosts fails evaluation where they don't reach each other
on the vpn it would go over:

- an allotment's replica and its host, on the allotment's `vpn`, or the first vpn they share (`org/allotment.nix`,
  `docs/parts/allotments.md`)
- a host that archives a principal and the archive's host, on `service.archive.vpn` (`nixos/org/state-archive.nix`,
  `docs/parts/state.md`).

An endpoint is dialed at what it resolves to, so a host on IPv6 alone is reached only from those that have IPv6.

## Routes

Two hosts may share more than one vpn, and what isn't tied to one goes over the most direct that works. A host's
`routes` has, for each host it reaches, that host's networks in that order (`org/host.nix`): on the vpn the other is the
gateway of, on the vpn it's the gateway of itself, on a mesh, then on a hub through a third host, each in the order of
its `vpns`.

- A host substitutes from each host with the nix-serve service at each of its `routes` to it, the first at priority 50,
  the next at 51 and so on, so that nix goes on to the next where one doesn't connect (`nixos/org/nix.nix`).
- `o11n` dials a host at its `fqdns`, its names on the vpns it's the gateway of, on a mesh, then on another's hub, then
  at its name in each of the org's `namespaces`, and takes the first that answers (`crates/o11n/src/route.rs`);
  `O11N_ROUTES` pins a host to an address instead.
- `o11n apply <host>...` and `o11n build <host>...` build each host on the first that answers of its `buildHosts`: the
  host itself, if it's one of the org's `build-hosts`, those it reaches without a host between, then those through a
  third host's hub, each in the org's order, and none it doesn't reach, which it couldn't fetch the build from
  (`crates/o11n/src/deploy.rs`). `--build-host`, or `BUILD_HOST`, names one instead, or `localhost`. `o11n build` builds
  the hosts that share a build host together, in one evaluation there (`build-system`, `nixos/services/nix-build.nix`),
  and so does `o11n apply --unit`, which builds every host before it switches any; without `--unit`, `o11n apply` builds
  and switches one host after the other, and stops at the first that fails.
