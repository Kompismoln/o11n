# Drive

A drive is its users' files, which they share and edit, and an office for them, and little else: Nextcloud, stripped to
that. Each runs in a container of the app's name, beside any other drive on the host, with its office in it
(`nixos/apps/drive.nix`), and has no state of its own but its database: its users' data is in their roots.

```toml
[store.alice]
smb = { host = "box.example.com", share = "alice", login = "alice" }

[app.drive]
id = 4
endpoint = "drive.example.com"
run-on-hosts = ["web"]
kind = "drive"
keycloak = "auth"
realm = "example"

[app.drive.roots]
alice = "store-alice"
carol = "app-site"

[app.drive.storages]
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
  - `richdocuments`, for its office, `user_oidc` with a `keycloak`, `files_external` with a storage, and
    `password_policy` and `twofactor_totp` without a `keycloak`.
- Calendar, contacts, Talk, the dashboard, photos and activity aren't among them; Nextcloud opens on its files, and a
  new user's are their own, with none of Nextcloud's samples, nor dav's example contact and event in the address book
  and calendar it makes them.

## Office

The office is Collabora's coolwsd, in the drive's container beside Nextcloud, at the drive's own endpoint: the app's
server serves `/browser`, `/hosting/discovery`, `/hosting/capabilities` and `/cool` from it, on loopback at port
`9980 + id`, as coolwsd binds no single address and each drive on a host shares its network. `nextcloud-office`, a
oneshot after `nextcloud-setup` and coolwsd, has `richdocuments` open documents at the app's `url`, which browsers open,
Nextcloud asks for its discovery and Collabora calls back to, and coolwsd serves that `url` alone. It fetches the
discovery, with `richdocuments:activate-config`, as richdocuments opens a document only with the one in its appdata,
which the home made anew has none of, and restarts until coolwsd answers. Its dictionaries are Swedish and English.

## Roots

A user's root is where Nextcloud keeps their data, in its own layout: their `files/`, `files_trashbin/`,
`files_versions/`, `uploads/` and `cache/`, the trash and versions of their storages among them. `roots` gives each
user's, by user, as the entity it's in and a directory there, `path`, `drive` by default, which has to be there
(`org/apps/roots.nix`):

- a store with an `smb` share: each of the app's hosts mounts `//<host>/<share>/<path>` at
  `<home>/nextcloud/data/<user>` under the app's home, as the app's user, over SMB 3.1.1, encrypted, logging in as the
  share's `login` with the store's `smb-password`, which the store has to grant the app's hosts. So one share holds a
  drive's root and a photos app's, each in a directory of its own (`docs/parts/photos.md`).
- a principal's home, by its handle: the host makes `<home>/<path>` as the principal's and mounts it with bindfs at the
  same place under the app's home, as the app's user's, written as the principal. What the principal writes there is the
  user's: a rolf app's home is one, whose `source`, `drive/files`, is the user's files. Neither names the other but the
  root. An owner that isn't on the drive's hosts fails evaluation.

The container starts only once each root is mounted, so that Nextcloud never writes a user's data into the directory
beneath: a root that doesn't mount keeps the whole drive down, and the host boots without it. Nextcloud reads a root at
the same place in the container, `/var/lib/nextcloud/data/<user>`, wherever it's mounted from. A root that names an
entity of neither kind, or no entity of the org's, fails evaluation, as do two roots in one directory, two apps' or two
users': give each but one a `path`.

## Storages

`storages` are each Nextcloud user's folders, by user and then by name, each of one kind (`org/apps/drive.nix`):

- `bind`: a directory on the app's hosts, which nextcloud's user can write in, bound into the container and mounted as a
  local storage at a folder of its name.
- `allotment` and `sftp`: an allotment or another SFTP server, at a folder of its name (`docs/parts/allotments.md`).
- `photos`: a photos app's drop folder, whose photos and videos the photos app takes into the user's library there,
  deleting them (`docs/parts/photos.md`). It's a directory of the photos app's, `<home>/drop/<user>/<drive>/<folder>`,
  which the host mounts with bindfs at `<home>/nextcloud/drops/<user>/<folder>` under the drive's home, as the app's
  user's, written as the photos app, and Nextcloud has as a bind. One whose photos app has no root of the user, or
  doesn't run on each of the drive's hosts, fails evaluation.
- `library`: a photos app's library of the user, read-only, as Immich files it (`docs/parts/photos.md`). Each of the
  app's hosts mounts the user's root there, `//<host>/<share>/<path>`, read-only at
  `<home>/nextcloud/libraries/<user>/<folder>` under the app's home, as the app's user, over SMB 3.1.1, encrypted,
  logging in with the store's `smb-password`, which the store has to grant the app's hosts, and Nextcloud has it as a
  bind, read-only: its user can read, copy and share from it, and change nothing there. It's mounted without cifs's
  cache of a directory's entries, `nohandlecache`, with which Nextcloud would miss for good what Immich files as it
  lists a folder. The container starts only once it's mounted, as with a root. One whose photos app has no root of the
  user fails evaluation.

Each is a folder in its user's root. A user without a root has files no one can write in: an empty directory of the Nix
store, bound read-only, with each of their storages a folder in it. What they keep there of Nextcloud's, the trash and
versions of their storages among it, is made anew as the container starts. A storage can be shared from with `sharing`.
A storage that is no one kind fails evaluation, as does a key that names no entity of the org's.

## Users

The users with roots or storages are the drive's: `nextcloud-users`, a oneshot after `nextcloud-setup`, makes each that
isn't, in the database, each time it starts, as Nextcloud would refuse to make one whose data, their root, is there
before them.

- With a `keycloak`, each is a user of user_oidc's, which provisions any other user of the realm as they log in, as
  `auto_provision` is on: one refused would have no way to log out of the realm, which the login page sends to. A
  Keycloak user without a root can write nothing of their own, at a quota of nothing, and logs out as any other.
- Without one, each is a user of nextcloud's own, without a password until `nextcloud-occ user:resetpassword` sets one.
- The files quota is nothing for a user nothing declares, as one user_oidc provisions or one made by hand, which can
  then make no file or folder of their own, and none for a user with a root. user_oidc sets a quota only from a `quota`
  claim, which the realm gives none of.

## Login

A drive with a `keycloak` has its users log in with the realm alone (`docs/parts/keycloak.md`):

- its login page sends to the realm, as user_oidc's `allow_multiple_user_backends` is off
- a Keycloak user is the user of their name of user_oidc's own: a user of nextcloud's own of that name can't log in with
  the realm, as soft auto-provisioning is off
- `nextcloud-oidc` disables each user of nextcloud's own each time it starts, and none can reset their password
- a client logs in with an app password, which login flow v2 makes once its user has logged in with the realm, and never
  with a password, as `token_auth_enforced` has it
<<<<<<< signed
- user_oidc sets a user's display name and email to the realm's each time they log in.
=======
- user_oidc sets a user's display name and email to the realm's each time they log in
- a browser's session lasts as long as the user's in the realm: user_oidc keeps its login's tokens, as
  `store_login_token` is on, renews them as they expire, and logs out when the realm refuses to; and Keycloak calls
  user_oidc's `/index.php/apps/user_oidc/backchannel-logout/<realm's displayName>` as it ends the user's session, which
  ends the session that logged in with it.
>>>>>>> @stamp

Nextcloud installs with no admin, and none is made: its settings are o11n's, and `nextcloud-occ` in the container
manages the rest.

## Moves

A move between two storages, a root and a storage or two storages, copies what's moved and then deletes it, in one
request, which Nextcloud's WebDAV gives no time limit and finishes as its client gives up: the app's server waits an
hour for its answer, as does the container's, so that a move of what takes up to an hour to copy answers as it ends. One
that fails leaves its source as it was, and what it copied.

## State

A drive's state is its database, which holds shares, versions' and the trash's records, tags, comments, favorites, app
passwords and sessions, and its users' roots and storages, which are theirs to keep. The container binds no home of the
host's: its own, `/var/lib/nextcloud`, its config, appdata and each user's data but a root, is made anew as it starts.
What it's made of is declared: its apps, its office, its realm, its users, their roots and their storages, which the
oneshots put back as they start.

- `nextcloud-setup` writes config.php, installed at the version `o11n_nextcloud`, a table of the database's, records,
  before it runs, and records the version after it, so that Nextcloud upgrades from it rather than install anew. A
  database without one installs into when it's empty, and fails `nextcloud-setup` otherwise, saying what to record.
- config.php's `secret`, with which Nextcloud encrypts what it keeps encrypted in the database, and its `passwordsalt`,
  without which it serves nothing, are the app's `secret-key`, which each unit that runs occ loads as a credential, and
  its `instanceid`, which names its appdata, `oc<id>`, the app's id as 8 hex digits. A new `secret-key` makes what's
  encrypted with the old unreadable, app passwords among it; the oneshots put back their own.
- The container restarts as a switch changes a sops file its secrets are in, its `secret-key`, `oidc-secret` and
  sftp-keys, as each is bound in as it starts and NixOS's activation restarts nothing for a secret; so does the keycloak
  app's `keycloak-realms`, which puts the client's `oidc-secret` in the realm.
- What's in the trash is deleted after 30 days, and a version after a year, the versions thinned meanwhile as Nextcloud
  does, `trashbin_retention_obligation` and `versions_retention_obligation`: Nextcloud's own default deletes only for
  room, which a user without a quota never runs out of.
- Its home is a principal's state (`docs/parts/state.md`): with `state.archives` it's archived with its database's dump
  in it. A root is its entity's to keep, a share's its server's and one in a home its principal's, archived with that
  home: an archive of the drive reads its home without what's mounted in it. The database's records of a root's trash
  and versions are archived with the drive, and a root on its own schedule.

## Testing

- `tests/nixos/drive.nix` evaluates its apps, office, login, retention, secret, instanceid, the roots it mounts and the
  storages it binds, and `tests/inventories/allotments/tests.nix` the roots and storages an org declares, their paths
  and collisions, and a root in a rolf app's home.
- `vmTests.drive` converts a document with its office, keeps its discovery, restarts it with its home made anew and its
  database as it was, writes in a bind and not in files without a root, writes in a root in an entity's home as the
  entity and reads what the entity writes there, and reads a library from a Samba share on `mx`, writes and deletes
  nothing there, and sees what's filed there after.
- `vmTests.keycloak` (`docs/parts/keycloak.md`) runs the login, a Keycloak user without a root who logs in, can't write
  and logs out, the user of Nextcloud's own it disables, and the apps it keeps.

## Migrating: Kompismoln/org's drive and drive-dev to roots

Each root moves into a directory of its share or home, `drive/`, which Nextcloud reads at the same place as before, so
its database stays as it is. Do drive-dev, on stationary, first, and drive, on helsinki, once drive-dev is as it should
be, with `app` the app's name. Kompismoln/org declares the roots: each store's `smb`, `[app.drive.roots]`, and
sverigesval's `source = "drive/files"`.

1. Stop the container, and the site whose home holds rolf's root, with `site` the site's app's name, as root on the
   host, `o11n ssh service-rescue <host> --user root`:

   ```sh
   systemctl stop container@$app $site
   ```

2. Move rolf's root into `drive/` in the site's home, each of Nextcloud's directories that's there:

   ```sh
   cd /var/lib/$site && install -d -o $site -g $site drive
   for dir in files files_trashbin files_versions uploads cache; do [[ -e $dir ]] && mv $dir drive/; done
   ```

   and, for drive, each user's into `drive/` in their store's share: on the storage box, make `drive` at the share's
   root and move each of the same directories that's there into it.

3. Apply the host; the container starts once each root is mounted from its directory, and the site builds from
   `drive/files`. `o11n status app-<app>` has `drive-root <user> <host> ok` for each.

## Work in progress

- Nothing tells Keycloak's groups to the drive: it has no admin.
- A drive's folders, `storages`, are named for what they reach rather than what they are, and are next to be settled.
