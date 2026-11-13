<<<<<<< signed
=======
# Immich

An immich is a photo library: each of its users' photos and videos, which their phones upload and Immich files. Each
runs in a container of the app's name, beside any other immich on the host (`nixos/apps/immich.nix`), and its users log
in with a Keycloak realm alone (`org/apps/immich.nix`).

```toml
[app.photos]
id = 6
endpoint = "photos.example.com"
run-on-hosts = ["web"]
grants = ["host:app-scheduler"]
immich = { keycloak = "auth", realm = "example" }

[app.photos.immich.storages]
alice.box = { host = "box.example.com", share = "backup/immich/alice", login = "u123", key = "store-box" }
```

## Settings

What's declared is the app's settings, which Immich reads from its config file alone, and its admin pages show as they
are:

- its login is the realm's, with the app's `oidc-secret`: its login page sends to it, password logins are off, and the
  realm's account page is where a user manages their account
- it files each original by the day it was taken, `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}`, in its user's library, and
  checks the file's hash as it moves it
- it doesn't back up its database, which is dumped into the app's home as any other's (`docs/parts/state.md`), nor
  checks for new versions
- with `principal.mail.send`, it mails as the app, logging in to submission on `mail.<endpoint>` with its `mail` key.

## Login

- Immich's client is confidential, with PKCE, and redirects to its login, `/auth/login`, its account linking,
  `/user-settings`, and its mobile app, `app.immich:///oauth-callback`. The keycloak keeps it in the realm
  (`docs/parts/keycloak.md`).
- Any user of the realm gets in: Immich makes them its user as they first log in, with their Keycloak username as their
  storage label, which names their library, `library/<username>`.
- Logging out of the realm logs out of immich: Keycloak calls its `/api/oauth/backchannel-logout` as it ends the user's
  session.
- With a keycloak over http, Immich takes its issuer over http too (`allowInsecureRequests`).

## Users

Immich makes no user of the realm's until it has an admin, which `immich-users`, a oneshot in its container after
Immich, makes of the app itself as it first starts, at the app's address, with a password no one keeps. No one logs in
as it: password logins are off, and the realm can't link a user to it by its address, as it has an OAuth id, `o11n`, the
realm gives no one. The host's root makes a user an admin with `immich-admin grant-admin` in the container.

Each time it starts, `immich-users` keeps each user's quota and library as declared, by a trigger on Immich's users, in
the database's `o11n` schema:

- a user with a box has no quota, as the box is their library, and any other a quota of nothing: they log in to a
  library they can upload nothing to, as it would be the app's state
- a user's storage label stays as they first logged in with it, so that their library stays theirs.

A user's name is a Keycloak username of lowercase letters, digits, `.`, `_` and `-`, other than `admin`, the app's own,
or the app fails evaluation.

## Boxes

A box is an SMB share that is a user's library, by user, logging in as its `login` with the `smb-password` of the entity
its `key` names, which has it while a box names it and grants the app's hosts (`org/apps/immich.nix`). Its `share` takes
a path after the share, as `backup/immich/alice`, so that one storage box holds each user's library and more.

- Each of the app's hosts mounts it at `<home>/immich/library/<user>` under the app's home, as the app's user, over SMB
  3.1.1, encrypted, and the container binds it where Immich keeps the user's library.
- The container starts only once each box is mounted, so that Immich never files a user's originals into the directory
  beneath.
- Immich alone writes in it: it keeps each original's path in its database, and a file moved, removed or added there
  other than through Immich is one it loses track of or never sees.

## State

The app's state is its database and its home (`docs/parts/state.md`). The container binds `<home>/immich` as Immich's
media, which holds what Immich makes of the originals, its thumbnails, the videos it encodes for the web and its users'
profile pictures, and what's uploaded until Immich files it. An archive of it leaves those thumbnails and videos out, by
the home's `.resticignore`, as Immich makes them anew, and reads it without the boxes mounted in it, which are their
server's to keep.

- Machine learning, which finds faces and what's in a photo, runs in the container beside Immich, at the app's own
  address, and keeps the models it downloads from Hugging Face in `/var/cache/<app>`, where the host keeps them.
- The host's postgresql has VectorChord preloaded, and `postgresql-setup` makes the extensions Immich needs in its
  database each time it starts, as a superuser, rebuilding its vector indexes as VectorChord changes.
- Immich's queue is in a redis in the container, lost as it stops, as in Immich's own setup.

## Testing

`vmTests.photos` runs `tests/inventories/mail`'s `photos` on `web`, beside its keycloak, with alice's box a Samba share
on `mx`: Immich is initialized with the app as its admin, which no one logs in as, alice logs in with the realm and what
she uploads is filed in her box, carol, with no box, logs in and uploads nothing, a quota and a storage label changed by
hand are as declared, the container made anew keeps what alice has, and alice logged out of the realm is logged out of
immich.

## Setting up: Kompismoln/org's photos and photos-dev

Each has a library of its own on the storage box, beside the drive's, and its users log in with `kompismoln`. Do
photos-dev, on stationary, first, and photos, on helsinki, once photos-dev is as it should be.

1. Point the endpoints' DNS at their hosts, as ACME asks for their certificates there, and declare each in `org.toml`,
   each with its own `id`, and each user's library a directory of the storage box's, `immich/` for photos and
   `immich-dev/` for photos-dev, beside the drive's:

   ```toml
   [app.photos]
   id = <id>
   endpoint = "photos.kompismoln.se"
   run-on-hosts = ["helsinki"]
   grants = ["host:app-scheduler"]
   immich = { keycloak = "keycloak", realm = "kompismoln" }

   [app.photos.immich.storages]
   alice.box = { host = "<box>.your-storagebox.de", share = "backup/immich/alice", login = "<login>", key = "store-box" }

   [app.photos-dev]
   id = <id>
   endpoint = "photos-dev.kompismoln.se"
   run-on-hosts = ["stationary"]
   grants = ["host:app-scheduler"]
   immich = { keycloak = "keycloak", realm = "kompismoln" }

   [app.photos-dev.immich.storages]
   alice.box = { host = "<box>.your-storagebox.de", share = "backup/immich-dev/alice", login = "<login>", key = "store-box" }
   ```

2. Make each library's directory on the storage box, then the apps' keys, and apply the keycloak's host first, as it
   puts the clients in the realm:

   ```sh
   o11n identity create app-photos
   o11n secret generate app-photos ssh-key
   o11n secret generate app-photos oidc-secret
   o11n identity create app-photos-dev
   o11n secret generate app-photos-dev ssh-key
   o11n secret generate app-photos-dev oidc-secret
   o11n apply helsinki
   o11n apply stationary
   ```

3. Each user logs in with "Log in with Kompismoln", and their phone's Immich app with the endpoint as its server.

## Work in progress

- Nothing says how an immich is in `o11n status`.
- Nothing maps Keycloak's groups or roles to Immich's admins.
- A user's library is a box or nothing: an allotment isn't one yet.
- Nothing gets photos from a drive into an immich.
>>>>>>> @stamp
