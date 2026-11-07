# Allotments

An allotment is room on a host for a principal: `allotment."<handle>@<host>"` in `org.toml`, with its `size`
(`org/allotment.nix`). The principal needn't be on the host, nor the allotment in its record, and the host lists its
allotments as `allotments` (`org/host.nix`).

```toml
[allotment."user-alice@web"]
size = "40G"
```

## On the host

A host with an allotment keeps it in a ZFS dataset of its own, `<storage>/allotments/<handle>`, under the dataset its
disk layouts mount at `o11n.preserve.storage`, whose encryption it inherits (`nixos/org/allotments.nix`). A host without
one fails evaluation. The dataset is mounted at the allotment's `path`, `/srv/allotments/<handle>`, outside what
preservation keeps, and it outlasts a boot as a dataset of its own does.

`allotment@<handle>` (`nixos/allotments.nix`) makes the dataset, and its parent unmounted, when it's missing, and each
time it runs sets its `refquota` to the `size`, which counts what's in it and not its snapshots, and its root to the
principal's uid and gid, mode `0700`. A principal that isn't on the host has an account there that owns it, with no
home, login or password.

## Replicas

An allotment's `replicas` are the hosts that keep a copy of it for its principal, which has to be on each, and to share
<<<<<<< signed
a vpn with the allotment's host. Syncthing syncs each with the allotment, both ways, as `allotment-sync@<id>`, `<id>`
being `<handle>.<host>` (`nixos/allotment-sync.nix`, `nixos/org/allotments.nix`):
=======
a vpn with the allotment's host, and reach it on the first they share (`docs/parts/vpns.md`). Syncthing syncs each with
the allotment, both ways, as `allotment-sync@<id>`, `<id>` being `<handle>.<host>` (`nixos/allotment-sync.nix`,
`nixos/org/allotments.nix`):
>>>>>>> @stamp

- each side is a device of its own, with a `syncthing-<id>` key of its host's, whose public key is the device's ID
  (`crates/o11n/src/keys.rs`): `o11n secret generate host-<host> syncthing-<id>` makes it, and a host without it fails
  evaluation
- the allotment's host listens on its address on the first vpn each replica shares with it, once networkd has brought
  that vpn's interface up, on port 22000 plus the principal's uid, open on that vpn alone, and runs Syncthing as the
  principal, its state in `/var/lib/allotment-sync/<id>` where the host keeps it
- a replica dials it there, and keeps the copy at `~/.o11n/allotments/<host>` in the principal's home, and Syncthing's
  state at `~/.o11n/syncthing/<host>`, running as the principal
- Syncthing knows nothing but its configuration, which each start writes anew: no discovery, relays, NAT traversal,
  reporting, and its API only on a socket in its state, `api.sock`.

## Status

On the allotment's host, `allotment-sync-status` (`nixos/allotment-sync.nix`) says, as JSON, how each allotment it
serves syncs, from Syncthing's API, which `switch-system allotments` runs for `o11n status`
(`crates/o11n/src/allotments.rs`):

- `allotment-sync <id> <replica>`: ok when the replica is connected and has all of the allotment, with no errors;
  skipped when it isn't connected but was seen within a week, and failed after that, or when it never was
- `allotment-conflicts <id>`: fails while the allotment holds a `*.sync-conflict-*` copy.
