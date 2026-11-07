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

An allotment's `replicas` are the hosts that keep a copy of it for its principal, which has to be on each, and reach the
allotment's host on its `vpn`, which both have to be on, or without one on the first vpn they share
(`docs/parts/vpns.md`). Syncthing syncs each with the allotment, both ways, as `allotment-sync@<id>`, `<id>` being
`<handle>.<host>` (`nixos/allotment-sync.nix`, `nixos/org/allotments.nix`):

- each side is a device of its own, with a `syncthing-<id>` key of its host's, whose public key is the device's ID
  (`crates/o11n/src/keys.rs`): `o11n secret generate host-<host> syncthing-<id>` makes it, and a host without it fails
  evaluation
- the allotment's host listens on its address on that vpn, for each replica, once networkd has brought that vpn's
  interface up, on port 22000 plus the principal's uid, open on that vpn alone, and runs Syncthing as the principal, its
  state in `/var/lib/allotment-sync/<id>` where the host keeps it
- a replica dials it there, and keeps the copy at `~/.o11n/allotments/<host>` in the principal's home, and Syncthing's
  state at `~/.o11n/syncthing/<host>`, running as the principal
- Syncthing knows nothing but its configuration, which each start writes anew: no discovery, relays, NAT traversal,
  reporting, and its API only on a socket in its state, `api.sock`.

<<<<<<< signed
=======
## Over SFTP

An allotment's `sftp` are the apps and hosts that reach it over SFTP as its principal, from each host they're on, an
app's `run-on-hosts` and a host itself, over its `vpn`, or without one over the first vpn that host shares with the
allotment's, as a replica would. The allotment's `logins` say how each logs in from each host (`org/allotment.nix`):

```toml
[allotment."user-alice@web"]
sftp = ["app-cloud"]
```

- Each logs in with its `sftp-key`, an RSA key, as nextcloud's SFTP takes no other kind:
  `o11n secret generate <handle> sftp-key` makes it, and the allotment's host without its public key fails evaluation.
- The allotment's host lets the key in as the principal from that host's address on the vpn alone, and gives it nothing
  but sftp, jailed to the allotments' directory, `/srv/allotments`, and starting in the allotment
  (`nixos/org/allotments.nix`). What it writes there is the principal's, as if a replica had synced it.
- A client on the allotment's host, or on one that doesn't reach it on a vpn, fails evaluation.

## In Nextcloud

A nextcloud's `external` are its external storages over SFTP, by the user each is for, then by its folder in their
files, each applicable to that user alone, and logging in with the app's `sftp-key` (`org/apps/nextcloud.nix`). Each
reaches an `allotment`, as its `logins` have it for the app, which has to be in its `sftp`, or an `sftp` server, one of
them; with `sharing` its user can share from it, which is how others get to it:

```toml
[app.cloud.nextcloud.external]
alice.web = { allotment = "user-alice@web", sharing = true }
bob.web = { allotment = "user-bob@web" }
alice.files = { sftp = { host = "files.example.com", login = "archive", root = "/" } }
```

- In nextcloud's container, `nextcloud-external`, a oneshot after `nextcloud-setup`, enables `files_external` and
  imports each, unless one is at its folder for its user as declared, which it replaces otherwise
  (`nixos/apps/nextcloud.nix`). It imports, as the import reads the private key on stdin, where `files_external:config`
  would take it on its command line.
- Nextcloud keeps the host key it first sees, and checks for changes as a folder is opened.
- An allotment that a replica syncs has two writers, nextcloud and Syncthing, which nothing coordinates.

>>>>>>> @stamp
## Status
<<<<<<< signed
=======
=======
## In Nextcloud

A nextcloud's `allotments` are the allotments it mounts as external storage for the user each is for, the nextcloud user
of its name, at `/<host>`, its host's name (`org/apps/nextcloud.nix`):

```toml
[app.cloud.nextcloud]
allotments = ["user-alice@web"]
```

Nextcloud reaches each over SFTP, on the allotment's `vpn`, or without one on the first vpn the host it runs on shares
with the allotment's host, as a replica would, and logs in as the principal with an RSA key, the app's `sftp-key`, as
nextcloud's SFTP has no other kind; `o11n secret generate app-<name> sftp-key` makes it, and an allotment's host without
its public key fails evaluation. An allotment that isn't a user's, or a host that runs nextcloud and has the allotment,
fail evaluation too.

- The allotment's host lets the key in as the principal from nextcloud's host's address on that vpn alone, and gives it
  nothing but sftp, jailed to the allotments' directory, `/srv/allotments`, and starting in the allotment
  (`nixos/org/allotments.nix`). What nextcloud writes there is the principal's, as if a replica had synced it.
- In nextcloud's container, `nextcloud-allotments`, a oneshot after `nextcloud-setup`, enables `files_external` and
  imports each mount, applicable to its user alone, unless one is there as declared, which it replaces otherwise
  (`nixos/apps/nextcloud.nix`). It imports, as the import reads the private key on stdin, where `files_external:config`
  would take it on its command line.
- Nextcloud keeps the host key it first sees, on the vpn, and checks for changes as a folder is opened.
>>>>>>> @stamp

On the allotment's host, `allotment-sync-status` (`nixos/allotment-sync.nix`) says, as JSON, how each allotment it
serves syncs, from Syncthing's API, which `switch-system allotments` runs for `o11n status`
(`crates/o11n/src/allotments.rs`):

- `allotment-sync <id> <replica>`: ok when the replica is connected and has all of the allotment, with no errors;
  skipped when it isn't connected but was seen within a week, and failed after that, or when it never was
- `allotment-conflicts <id>`: fails while the allotment holds a `*.sync-conflict-*` copy.
