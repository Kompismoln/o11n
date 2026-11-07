# State

A principal's state is its home. A principal with a home, `principal.home` other than `/var/empty`, has
`principal.state` (`org/state.nix`), and one without has none and can't be given one. `nixos/org/state.nix` makes a host
keep the state of each principal on it.

## Kept

What a host does with a principal's home follows from its `state`:

- with `state.preserve = false`, the home is lost as a host with an ephemeral root boots;
- by default, the home outlasts a boot, and is snapshotted;
- with `state.archives`, it is also archived to each host named, which a home that isn't preserved can't be.

Preserving what a host itself keeps, such as `/var/lib/nixos` or its machine-id, is the host's, in `nixos/preserve.nix`,
not the state's.

## Persistence

On a host with `o11n.preserve.enable`, a preserved home is a directory of `o11n.preserve.directories`, which
preservation keeps under `o11n.preserve.storage` and mounts at the home (`nixos/preserve.nix`). On any other host every
home outlasts a boot.

## Snapshots

`state-snapshot@<id>` (`nixos/org/snapshot.nix`) snapshots the subvolume or dataset a preserved home is on, btrfs or
zfs, read-only, and links the home's place in it at `/run/o11n/state/<id>`. It keeps one snapshot a principal, replaced
as the next is taken, and holds `/run/o11n/state/<id>.lock` while it does. On another file system it links the home as
it is, and a host with a home archived there warns that each archive reads it as it changes (`nixos/org/state.nix`).

## Dumps

`o11n.dumps` (`nixos/dump.nix`) has a database's server dump it into its owner's home, `dbdump.sql` by default, as
`<name>-dump`, which each snapshot of the owner's state requires and runs after, so that a snapshot holds a dump of the
database as it was then. `nixos/postgresql.nix` and `nixos/mysql.nix` declare one for each of their databases.

## Archive

A host with a role whose services hold `archive` and whose stores hold `archives` runs the archive service
(`nixos/services/archive.nix`): restic's rest-server, on the vpn `service.archive.vpn` names, with that vpn's
namespace's tls-cert. It keeps a repo for each principal, at `/<id>/` in the archives store's home, which the principal
can reach alone, with its `archive-passwd`, whose htpasswd is public, so that the archive holds no secret of the
principals it serves. It's append-only: a principal adds to its repo, and can't remove what it has added.

A host that archives a principal has to reach the archive's host on `service.archive.vpn` (`docs/parts/vpns.md`).

A principal with `state.archives` has an `archive-passwd` and a `restic-key`, whatever its class, and
`o11n secret generate <id> <key>` makes each. On each host it's on, `state-archive@<id>:<archive>`
(`nixos/org/state-archive.nix`) takes a snapshot, holds its lock, mounts it at the home in the unit's own namespace and
backs it up, as the home, to the principal's repo on the archive host. An archive with a `schedule` runs on it, a
systemd calendar event, and one without when started. One that fails mails the mail server's `admin` as the principal,
which is to send mail, as an archive service that fails does as itself (`docs/parts/mail.md`).

A `.resticignore` in the home reads as a `.gitignore`: a pattern with a slash but at its end is anchored to the file's
directory, one without matches at any depth below it, a `!` keeps what it matches, and the deeper file wins.

## Operating an archive

The operator reaches a repo over ssh to the archive host, as root with `service-rescue`'s ssh-key, through its
`archive-restic <id> <restic's arguments>`, which reads the repo's `restic-key` from stdin and runs restic as the
archives store, not as rest-server (`crates/o11n/src/state.rs`). `--from <archive>` names one of a principal's archives,
which a command that reads one archive needs if it has several.

- `o11n state snapshots <id>` lists the snapshots of each archive.
- `o11n state prune <id>` forgets and prunes what each archive's `prune` doesn't keep, as restic forget's `--keep-*`
  flags; an archive without one keeps everything. Nothing prunes unless the operator does.
- `o11n state restore <id> [--of <host>] [--snapshot <id>] (--to <host> | --dir <dir>)` restores a snapshot, the latest
  by default, of the home as `<host>` had it, by default the host restored to or the principal's only one: into the home
  on `--to`'s host, which has to be empty, or as `<dir>/<id>@<host>-<snapshot>.tar.zst`.

## Fetch

`o11n state fetch <id> [--dir <dir>]` (`crates/o11n/src/state.rs`) downloads a principal's home from each host it's on,
as root with `service-rescue`'s ssh-key, into `<dir>/<id>@<host>-<time>.tar.zst`. It reads the home as it is, not a
snapshot or an archive.

## Setting up: an archive at pelle for klimatkalendern at helsinki

Kompismoln/org already has an archive at pelle, short of anyone archiving to it:

- `[role.archive]` has the `archive` service and the `archives` store, and pelle has the role.
- `[service.archive]` has an `id` and `vpn = "wg0"`, which helsinki is on too, and serves as `archive-pelle.km`.
- `[service.domain-km]` grants the km namespace's tls-cert to `host:archive`, as the archive serves with it.
- `[store.archives]` has an `id`, `principal.hasSFTP = false` and `principal.hasPublicKey = false`.

It takes the org on o11n as it is here, with klimatkalendern as a `mobilizon` app (`org/apps/mobilizon.nix`), whose
database `nixos/apps/mobilizon.nix` declares, and so dumps.

1. Archive klimatkalendern's state to pelle, daily, say what `o11n state prune` keeps, and have it send mail, as it
   tells of a failed archive, under `[app.klimatkalendern]` in `org.toml`:

   ```toml
   principal.mail.send = true
   principal.state.archives.pelle.schedule = "daily"
   principal.state.archives.pelle.prune = { keep-daily = 7, keep-weekly = 5, keep-monthly = 12, keep-yearly = 1 }
   ```

   The archive service tells of its own failures as `archive@kompismoln.se`: under `[service.archive]`, set
   `principal.mail.send = true` and `grants = ["host:archive", "host:mailserver"]`.

2. Generate klimatkalendern's `archive-passwd`, its `restic-key` if `o11n secret show app-klimatkalendern restic-key`
   has none, and the `mail` of each:

   ```sh
   o11n secret generate app-klimatkalendern archive-passwd
   o11n secret generate app-klimatkalendern restic-key
   o11n secret generate app-klimatkalendern mail
   o11n identity create service-archive
   o11n secret generate service-archive mail
   ```

   The `restic-key` encrypts the archive: lose it, and the archive is lost with it.

3. Apply pelle first, whose rest-server lets klimatkalendern in once it has its `archive-passwd`'s htpasswd, then
   helsinki, the mail server too, which gets `state-archive@app-klimatkalendern:pelle` and its timer:

   ```sh
   o11n apply pelle
   o11n apply helsinki
   ```

4. Archive once rather than wait for the timer, and see the snapshot on pelle:

   ```sh
   o11n ssh service-rescue helsinki --user root systemctl start state-archive@app-klimatkalendern:pelle
   o11n state snapshots app-klimatkalendern
   ```

   It runs `klimatkalendern-pgsql-dump` first, into `/var/lib/klimatkalendern/dbdump.sql`, and the snapshot of
   helsinki's btrfs storage after it. A snapshot that holds the dump can be restored as
   `o11n state restore app-klimatkalendern --dir .`.

5. Prune now and then: `o11n state prune app-klimatkalendern`.

## Work in progress

- `nixos/org/state-archive.nix` repeats the archive's port rather than reading it from `nixos/services/archive.nix`.
- `o11n state fetch` reads the home as it changes; it's to take a snapshot first, and with it the dumps, and read that,
  and may be renamed, such as to `rescue-fetch`.
- A dump of an owner whose home isn't preserved is kept, though the home goes as the host boots.
- `hasHome`, `home` and `homeMode` may move from `principal` into `principal.state`.
- `state-snapshot@` keeps one snapshot a principal. The org's commented-out `[app.klimatkalendern-dev.state]` sketches
  more: snapshots hourly, kept on the host for a day, and a separate policy for each place a snapshot is kept.
