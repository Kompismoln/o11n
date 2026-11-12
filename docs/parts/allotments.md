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
principal's uid and gid, mode `0700`, or `0750` for a principal with `members`, who read it as members of its group
(`nixos/org/allotments.nix`). A principal that isn't on the host has an account there that owns it, with no home, login
or password.

## Torrents

An allotment with `torrent = true` is one the torrent-server on its host downloads into, as its principal's, which needs
the host to have the service, and the allotment no `replicas` (`docs/parts/torrent.md`).

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

### On the desktop

Where Cinnamon runs, a replica is on its principal's Desktop as a link named after the org, or after the org and the
allotment's host where the principal keeps more than one there, with the org's `theme.logo` as its icon
(`nixos/org/allotments.nix`). `allotment-desktop@<id>`, a user service of the principal's, makes the link where nothing
is, and every 5 seconds badges it with an emblem of how it syncs, from `allotment-sync-status <id>`
(`nixos/allotment-sync.nix`):

- `emblem-default`: the allotment's host is connected and has all of it
- `emblem-synchronizing`: connected, and either side still syncing
- `emblem-unreadable`: the allotment's host isn't connected
- `emblem-important`: an error, or a `*.sync-conflict-*` copy in the replica.

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
- The allotment's host lets the key in as the principal from that host's addresses on the vpn alone, and gives it
  nothing but sftp, jailed to the allotments' directory, `/srv/allotments`, and starting in the allotment
  (`nixos/org/allotments.nix`). What it writes there is the principal's, as if a replica had synced it.
- The allotment's host has an RSA host key besides its own, `/keys/ssh_host_rsa_key`, which sshd makes as it first
  starts, and takes `hmac-sha2-256` besides NixOS's MACs, as nextcloud's SFTP, phpseclib 2, verifies no other kind of
  host key and has none of those MACs. OpenSSH's clients keep to the host's own key and NixOS's MACs.
- A client on the allotment's host, or on one that doesn't reach it on a vpn, fails evaluation.
- Of an allotment with replicas, a client follows what they change in it: `allotment-changes@<id>` records each batch
  Syncthing finishes of their changes, from its `ItemFinished` events and not from what other writers change, in
  `/run/allotment-changes/<id>` (`nixos/allotment-sync.nix`), and the key logs in as `allotment-changes` from the same
  addresses, whose command says `changed` as it connects and as the record changes, for the allotment the client names
  of those it reaches, and nothing else (`nixos/allotment-changes.nix`, as `nixos/org/allotments.nix` grants it).

## In Nextcloud

A nextcloud's `storages` of an `allotment` or an `sftp` server are external storages over SFTP, by the Nextcloud user
each is for, then by its folder in their files, each applicable to that user alone (`org/apps/nextcloud.nix`,
`docs/parts/nextcloud.md`). The user needn't be one of the org's: a Keycloak account in the app's realm is a Nextcloud
user of its own (`docs/parts/keycloak.md`). An `allotment` is reached as its `logins` have it for the app, which has to
be in its `sftp`, logging in with the app's `sftp-key`; with `sharing` its user can share from it, which is how others
get to it:

```toml
[app.cloud.nextcloud.storages]
alice.web = { allotment = "user-alice@web", sharing = true }
bob.web = { allotment = "user-bob@web" }
alice.files = { sftp = { host = "files.example.com", login = "archive", root = "/" } }
carol.box = { sftp = { host = "box.example.com", login = "carol", key = "store-box" } }
```

- An `sftp` server's mount logs in with the app's `sftp-key`, or with that of the entity its `key` names, as a store
  that owns a server outside the org: the entity has an `sftp-key` while a mount names it, and grants the app's hosts,
  which decrypt it (`docs/parts/secrets.md`). A `key` that names no entity of the org's fails evaluation, as does a key
  without its public key, on the app's host (`nixos/apps/nextcloud.nix`).
- In nextcloud's container, `nextcloud-external`, a oneshot after `nextcloud-setup`, enables `files_external` and
  imports each, unless one is at its folder for its user as declared, which it replaces otherwise
  (`nixos/apps/nextcloud.nix`). It imports, as the import reads the private key on stdin, where `files_external:config`
  would take it on its command line.
- Nextcloud reaches an allotment at its host's IPv4 address on the vpn, as it keeps the host keys it knows as
  `host::key` lines, split at the first `::`. It keeps the host key it first sees, and checks for changes as a folder is
  opened.
- Each of its storages, its boxes too, checks a folder for changes as it's opened, by its mtime, which a file added,
  removed or renamed in it changes, as Syncthing does, and the change shows in that folder and the etags above it:
  `filesystem_check_changes = 1` in its settings, as the import leaves out the mount option the web UI sets, without
  which it would never check.
- Of an allotment with replicas, whose clients sync by the etags from the top and wouldn't get what changes in a folder
  no one opens, it follows what the replicas change: `nextcloud-changes-<user>-<folder>` in its container logs in as
  `allotment-changes` to the allotment's host, with the mount's key, verifying the host's `ssh-key`, which the app's
  host without fails evaluation, and scans the mount as it connects and once each batch of changes has been quiet for 5
  seconds, reconnecting as the connection drops (`nixos/apps/nextcloud.nix`). A scan with errors, which `occ files:scan`
  exits 0 with and counts in its summary alone, the listener restarts on, to connect and scan again; a storage it failed
  to reach, nextcloud skips for 10 minutes, and one it failed to log in to for 30, so it catches up after them. Any
  other mount it knows changes of as their folders are opened, or after `occ files:scan`.
- An allotment that a replica syncs has two writers, nextcloud and Syncthing, which nothing coordinates.

### Boxes

A nextcloud's `storages` of a `box` are the Nextcloud users whose data, their files, versions and trash alike, is an SMB
share, by user, each logging in as its `login` with the `smb-password` of the entity its `key` names, which has it while
a box names it and grants the app's hosts (`org/apps/nextcloud.nix`):

```toml
[app.cloud.nextcloud.storages]
carol.box.box = { host = "box.example.com", share = "carol", login = "carol", key = "store-box" }
```

- Each of the app's hosts mounts the share at `<home>/nextcloud/data/<user>` under the app's home, as the app's user,
  over SMB 3.1.1, encrypted, with the credentials sops-nix renders from the password, and the container binds it where
  Nextcloud keeps the user's data (`nixos/apps/nextcloud.nix`).
- The container starts only once each share is mounted, so that Nextcloud never writes a user's data into the directory
  beneath: a share that doesn't mount keeps the whole nextcloud down, and the host boots without it.
- What changes on the share other than through Nextcloud, Nextcloud knows of after `occ files:scan <user>`.
- The share is a file system of its own, which a snapshot of the app's state doesn't hold, nor an archive of it, and
  holds all of the user's data, which another nextcloud could mount as well.

## Status

On the allotment's host, `allotment-sync-status [id]` (`nixos/allotment-sync.nix`) says, as JSON, how each allotment it
serves syncs, or the one named, from Syncthing's API, which `switch-system allotments` runs for `o11n status`
(`crates/o11n/src/allotments.rs`):

- `allotment-sync <id> <replica>`: ok when the replica is connected and has all of the allotment, with no errors;
  skipped when it isn't connected but was seen within a week, and failed after that, or when it never was
- `allotment-conflicts <id>`: fails while the allotment holds a `*.sync-conflict-*` copy.

On a host a nextcloud with `storages` runs on, `nextcloud-status-<app>` says how each is, which
`switch-system nextcloud` runs for `o11n status` (`crates/o11n/src/nextcloud.rs`):

- `nextcloud-home <user> <host>`: the share is mounted at the user's data, and the app's user can write to it
- `nextcloud-external <user>/<folder> <host>`: Nextcloud has the external storage, and `files_external:verify` says it's
  ok, or else fails with what it says.
- `nextcloud-changes <user>/<folder> <host>`: of an allotment with replicas, `nextcloud-changes-<user>-<folder>` is
  active, and has been for 20 seconds, as its ssh gives up connecting after 10 and it restarts.
