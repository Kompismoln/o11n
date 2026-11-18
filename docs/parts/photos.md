# Photos

A photos app is a photo library: each of its users' photos and videos, which their phones upload and Immich files. Each
runs in a container of the app's name, beside any other photos app on the host (`nixos/apps/photos.nix`), and its users
log in with a Keycloak realm alone (`org/apps/photos.nix`).

```toml
[store.alice]
smb = { host = "box.example.com", share = "alice", login = "alice" }

[app.photos]
id = 6
endpoint = "photos.example.com"
run-on-hosts = ["web"]
grants = ["host:app-scheduler"]
kind = "photos"
keycloak = "auth"
realm = "example"
roots.alice = "store-alice"
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
<<<<<<< signed
- with `principal.mail.send`, it mails as the app, logging in to submission on `mail.<endpoint>` with its `mail` key.
=======
- with `principal.mail.send`, it mails as the app, logging in to submission on its mail server with its `mail` key.
>>>>>>> @stamp

## Login

- Immich's client is confidential, with PKCE, and redirects to its login, `/auth/login`, its account linking,
  `/user-settings`, and its mobile app, `app.immich:///oauth-callback`. The keycloak keeps it in the realm
  (`docs/parts/keycloak.md`).
- Any user of the realm gets in: Immich makes them its user as they first log in, with their Keycloak username as their
  storage label, which names their library, `library/<username>`.
- Logging out of the realm logs out of the app: Keycloak calls its `/api/oauth/backchannel-logout` as it ends the user's
  session.
- With a keycloak over http, Immich takes its issuer over http too (`allowInsecureRequests`).

## Users

Immich makes no user of the realm's until it has an admin, which `immich-users`, a oneshot in its container after
Immich, makes of the app itself as it first starts, at the app's address, with a password no one keeps. No one logs in
as it: password logins are off, and the realm can't link a user to it by its address, as it has an OAuth id, `o11n`, the
realm gives no one. The host's root user makes a user an admin with `immich-admin grant-admin` in the container.

Each time it starts, `immich-users` keeps each user's quota and library as declared, by a trigger on Immich's users, in
the database's `o11n` schema:

- a user with a root has no quota, as the root is their library, and any other a quota of nothing: they log in to a
  library they can upload nothing to, as it would be the app's state
- a user's storage label stays as they first logged in with it, so that their library stays theirs.

A user's name is a Keycloak username of lowercase letters, digits, `.`, `_` and `-`, other than `admin`, the app's own,
or the app fails evaluation.

## Roots

A user's root is their library, where Immich files their originals by the day each was taken. `roots` gives each user's,
by user, as a store with an `smb` share and a directory in it, `path`, `photos` by default, which has to be there, so
that one share holds a drive's root and a photos app's, each in a directory of its own (`org/apps/roots.nix`,
`docs/parts/drive.md`). A root that names anything but a store with an `smb`, or one directory that another root is,
fails evaluation.

- Each of the app's hosts mounts `//<host>/<share>/<path>` at `<home>/immich/library/<user>` under the app's home, as
  the app's user, over SMB 3.1.1, encrypted, logging in as the share's `login` with the store's `smb-password`, which
  the store has to grant the app's hosts, and the container binds it where Immich keeps the user's library.
- `<app>-library`, a oneshot each mount requires, makes `<home>/immich` and its `library` the app's user's before it's
  mounted, as a host boots and as a switch starts a new mount, for systemd would make them root's.
- The container starts only once each root is mounted, so that Immich never files a user's originals into the directory
  beneath.
- Immich alone writes in it: it keeps each original's path in its database, and a file moved, removed or added there
  other than through Immich is one it loses track of or never sees.

## State

The app's state is its database and its home (`docs/parts/state.md`). The container binds `<home>/immich` as Immich's
media, which holds what Immich makes of the originals, its thumbnails, the videos it encodes for the web and its users'
profile pictures, and what's uploaded until Immich files it. An archive of it leaves those thumbnails and videos out, by
the home's `.resticignore`, as Immich makes them anew, and reads it without the roots mounted in it, which are their
server's to keep.

- Machine learning, which finds faces and what's in a photo, runs in the container beside Immich, at the app's own
  address, and keeps the models it downloads from Hugging Face in `/var/cache/<app>`, where the host keeps them.
- The host's postgresql has VectorChord preloaded, and `postgresql-setup` makes the extensions Immich needs in its
  database each time it starts, as a superuser, rebuilding its vector indexes as VectorChord changes.
- Immich's queue is in a redis in the container, lost as it stops, as in Immich's own setup.

## Testing

`vmTests.photos` runs `tests/inventories/mail`'s `photos` on `web`, beside its keycloak, with alice's root `photos/` in
a Samba share on `mx`: Immich is initialized with the app as its admin, which no one logs in as, alice logs in with the
realm and what alice uploads is filed in that root, carol, with no root, logs in and uploads nothing, a quota and a
storage label changed by hand are as declared, the container made anew keeps what alice has, and alice logged out of the
realm is logged out of the app. `tests/inventories/allotments/tests.nix` has a photos app's root in a share alone.

## Setting up: Kompismoln/org's photos and photos-dev

Each user's root is a directory of their store's share, beside their drive's, and its users log in with `kompismoln`. Do
photos-dev, on stationary, first, and photos, on helsinki, once photos-dev is as it should be.

1. Point the endpoints' DNS at their hosts, as ACME asks for their certificates there, and declare each in `org.toml`,
   each with its own `id`, and each user's root in their store, `photos/` for photos and `photos-dev/` for photos-dev,
   beside `drive/`, with each store granting stationary too:

   ```toml
   [app.photos]
   id = <id>
   endpoint = "photos.kompismoln.se"
   run-on-hosts = ["helsinki"]
   grants = ["host:app-scheduler"]
   kind = "photos"
   keycloak = "keycloak"
   realm = "kompismoln"
   roots.alex = "store-alex"

   [app.photos-dev]
   id = <id>
   endpoint = "photos-dev.kompismoln.se"
   run-on-hosts = ["stationary"]
   grants = ["host:app-scheduler"]
   kind = "photos"
   keycloak = "keycloak"
   realm = "kompismoln"
   roots.alex = { entity = "store-alex", path = "photos-dev" }
   ```

2. Make each root's directory on the storage box, then the apps' keys, and apply the keycloak's host first, as it puts
   the clients in the realm:

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

- Nothing says how a photos app is in `o11n status`.
- Nothing maps Keycloak's groups or roles to Immich's admins.
- A user's library is a share or nothing: an allotment isn't one yet.
- Nothing gets photos from a drive into a photos app.
