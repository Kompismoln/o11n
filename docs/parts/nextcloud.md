# Nextcloud

A nextcloud is a drive: its users' files, which they share and edit, and an office for them, and little else. Each runs
in a container of the app's name, beside any other nextcloud on the host, with its office in it
(`nixos/apps/nextcloud.nix`), and has no state of its own but its database: its users' files are their storages.

```toml
[app.drive]
id = 4
endpoint = "drive.example.com"
run-on-hosts = ["web"]
nextcloud = { keycloak = "auth", realm = "example" }

[app.drive.nextcloud.storages]
alice.box.box = { host = "box.example.com", share = "alice", login = "alice", key = "store-box" }
alice.web = { allotment = "user-alice@web", sharing = true }
bob.pub = { bind = "/srv/pub" }
```

## Apps

- The app store is closed: Nextcloud installs no app, and has only those it ships and those o11n gives it.
- `nextcloud-apps`, a oneshot in the container after `nextcloud-setup`, disables each enabled app but those of its
  files, the ones Nextcloud keeps enabled, and those its settings call for, each time it starts:
  - its files': `files_sharing`, `files_trashbin`, `files_versions`, `files_downloadlimit`, `files_reminders`,
    `files_lock`, `files_pdfviewer`, `text`, `comments`, `systemtags`, `notifications`
  - its admin's: `bruteforcesettings`, `logreader`, `serverinfo`
  - Nextcloud's own, as `core/shipped.json` has them always enabled, `files`, `dav`, `viewer` and `settings` among them
  - `richdocuments`, for its office, `user_oidc` with a `keycloak`, `files_external` with a storage but a box, and
    `password_policy` and `twofactor_totp` without a `keycloak`.
- Calendar, contacts, Talk, the dashboard, photos and activity aren't among them; Nextcloud opens on its files, and a
  new user's are their own, with none of Nextcloud's samples.

## Office

The office is Collabora's coolwsd, in the drive's container beside Nextcloud, at the drive's own endpoint: the app's
server serves `/browser`, `/hosting/discovery`, `/hosting/capabilities` and `/cool` from it, on loopback at port
`9980 + id`, as coolwsd binds no single address and each nextcloud on a host shares its network. `nextcloud-office`, a
oneshot after `nextcloud-setup`, has `richdocuments` open documents at the app's `url`, which browsers open, Nextcloud
asks for its discovery and Collabora calls back to, and coolwsd serves that `url` alone. Its dictionaries are Swedish
and English.

## Storages

`storages` are each Nextcloud user's, by user and then by name, each of one kind (`org/apps/nextcloud.nix`):

- `box`: an SMB share that is the user's data, their files, versions and trash, which a nextcloud mounts as such, and so
  any other could as well. A user has one box at most, and their other storages are folders in it.
- `bind`: a directory on the app's hosts, which nextcloud's user can write in, bound into the container and mounted as a
  local storage at a folder of its name. A nextcloud-rolf's folder is one, which the nextcloud makes in its home.
- `allotment` and `sftp`: an allotment or another SFTP server, at a folder of its name (`docs/parts/allotments.md`).

A user without a box has files no one can write in: an empty directory of the store, bound read-only, with each of their
storages a folder in it. What they keep there of Nextcloud's, their trash and versions of their other storages among it,
is made anew as the container starts. Any storage but a box can be shared from with `sharing`.

A storage that is no one kind, or a user with two boxes, fails evaluation, as does a key that names no entity of the
org's.

## Users

The users with storages are the drive's: `nextcloud-users`, a oneshot after `nextcloud-setup`, makes each that isn't, in
the database, each time it starts, as Nextcloud would refuse to make one whose data, their box, is there before them.

- With a `keycloak`, each is a user of user_oidc's, and user_oidc provisions no other, as `auto_provision` is off: a
  Keycloak user without storages can't log in.
- Without one, each is a user of nextcloud's own, without a password until `nextcloud-occ user:resetpassword` sets one.
- The files quota is nothing for a user nothing declares, as one made by hand, and none for a user with a box.

## Login

A nextcloud with a `keycloak` has its users log in with the realm alone (`docs/parts/keycloak.md`):

- its login page sends to the realm, as user_oidc's `allow_multiple_user_backends` is off
- a Keycloak user is the user of their name of user_oidc's own: a user of nextcloud's own of that name can't log in with
  the realm, as soft auto-provisioning is off
- `nextcloud-oidc` disables each user of nextcloud's own each time it starts, and none can reset their password
- a client logs in with an app password, which login flow v2 makes once its user has logged in with the realm, and never
  with a password, as `token_auth_enforced` has it.

Nextcloud installs with no admin, and none is made: its settings are o11n's, and `nextcloud-occ` in the container
manages the rest.

## State

A nextcloud's state is its database, which holds shares, versions' and the trash's records, tags, comments, favorites,
app passwords and sessions, and its users' storages, which are theirs to keep. The container binds no home of the
host's: its own, `/var/lib/nextcloud`, its config, appdata and each user's data but a box, is made anew as it starts.
What it's made of is declared: its apps, its office, its realm, its users and their storages, which the oneshots put
back as they start.

- `nextcloud-setup` writes config.php, installed at the version `o11n_nextcloud`, a table of the database's, records,
  before it runs, and records the version after it, so that Nextcloud upgrades from it rather than install anew. A
  database without one installs into when it's empty, and fails `nextcloud-setup` otherwise, saying what to record.
- config.php's `secret`, with which Nextcloud encrypts what it keeps encrypted in the database, and its `passwordsalt`,
  without which it serves nothing, are the app's `secret-key`, which each unit that runs occ loads as a credential, and
  its `instanceid`, which names its appdata, `oc<id>`, the app's id as 8 hex digits. A new `secret-key` makes what's
  encrypted with the old unreadable, app passwords among it; the oneshots put back their own.
- What's in the trash is deleted after 30 days, and a version after a year, the versions thinned meanwhile as Nextcloud
  does, `trashbin_retention_obligation` and `versions_retention_obligation`: Nextcloud's own default deletes only for
  room, which a user without a quota never runs out of.
- Its home is a principal's state (`docs/parts/state.md`): with `state.archives` it's archived with its database's dump
  and the binds made there in it. A box is its server's to keep: an archive reads the home without what's mounted in it.

## Testing

- `tests/nixos/nextcloud.nix` evaluates its apps, office, login, retention, secret, instanceid and the storages it
  binds, and `tests/inventories/allotments/tests.nix` the storages an org declares and a nextcloud-rolf's bind.
- `vmTests.drive` converts a document with its office, restarts it with its home made anew and its database as it was,
  and writes in a bind and not in files without a box.
- `vmTests.keycloak` (`docs/parts/keycloak.md`) runs the login, a Keycloak user without storages refused, the user of
  nextcloud's own it disables, and the apps it keeps.

## Migrating: Kompismoln/org's drive and drive-dev to storages, a home made anew and the office in the drive

Each keeps its database, and loses its home, `<home>/nextcloud`, but what's moved out of it first. Do drive-dev, on
stationary, first, and drive, on helsinki, once drive-dev is as it should be. Run the host's commands as root,
`o11n ssh service-rescue <host> --user root`, with `app` the app's name and `home` its principal's home.

1. Declare each user's storages in `org.toml`, in `[app.<app>.nextcloud.storages]`: each `homes.<user>` a
   `<user>.box.box`, each `external.<user>.<folder>` a `<user>.<folder>`, and a `bind` for each user whose files were in
   the home, a directory moved there in 3. Take out `nextcloud.collabora` and the `[app.office]` collabora app, and
   point its endpoint's DNS nowhere, as the office is the drive's own now. A user nothing declares can't log in.
2. Record the version the old home's config.php has, as the first start without it would otherwise fail:

   ```sh
   version=$(nixos-container run $app -- nextcloud-occ config:system:get version)
   runuser -u $app -- psql -d $app -c "create table o11n_nextcloud (key text primary key, value text not null)" \
     -c "insert into o11n_nextcloud values ('version', '$version')"
   ```

3. Stop the container and move each user's files without a box to the directory of their bind, with rolf's `+pub` to
   `$home/binds/rolf/+pub`, which drive's nextcloud-rolf builds from, as the app's user:

   ```sh
   systemctl stop container@$app
   mkdir -p $home/binds/rolf && mv $home/nextcloud/data/rolf/files/+pub $home/binds/rolf/
   ```

4. Apply the host; the container starts with its home made anew, and `nextcloud-setup` upgrades from the version
   recorded. Have each user log in, and scan what they have, as what's in a bind or box is Nextcloud's once scanned:

   ```sh
   o11n apply <host>
   nixos-container run $app -- nextcloud-occ files:scan --all
   ```

5. Once nothing is missed, remove the old home, `$home/nextcloud`, but the mount points of the boxes, which the host
   mounts there.

## Work in progress

- Nothing tells Keycloak's groups to nextcloud: it has no admin.
- A user of user_oidc's that o11n makes has no display name or email until Keycloak's are mapped to it.
