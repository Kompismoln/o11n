# Nextcloud

A nextcloud is a drive: its users' files, which they share and edit, and an office for them with a `collabora`, and
little else. Each runs in a container of the app's name, beside any other nextcloud on the host
(`nixos/apps/nextcloud.nix`).

```toml
[app.drive]
id = 4
endpoint = "drive.example.com"
run-on-hosts = ["web"]
nextcloud = { collabora = "office", keycloak = "auth", realm = "example" }
```

## Apps

- The app store is closed: Nextcloud installs no app, and has only those it ships and those o11n gives it.
- `nextcloud-apps`, a oneshot in the container after `nextcloud-setup`, disables each enabled app but those of its
  files, the ones Nextcloud keeps enabled, and those its settings call for, each time it starts:
  - its files': `files_sharing`, `files_trashbin`, `files_versions`, `files_downloadlimit`, `files_reminders`,
    `files_lock`, `files_pdfviewer`, `text`, `comments`, `systemtags`, `notifications`
  - its admin's: `bruteforcesettings`, `logreader`, `serverinfo`
  - Nextcloud's own, as `core/shipped.json` has them always enabled, `files`, `dav`, `viewer` and `settings` among them
  - `richdocuments` with a `collabora`, `user_oidc` with a `keycloak`, `files_external` with an `external`
    (`docs/parts/allotments.md`), and `password_policy` and `twofactor_totp` without a `keycloak`.
- Calendar, contacts, Talk, the dashboard, photos and activity aren't among them; Nextcloud opens on its files, and a
  new user's are their own, with none of Nextcloud's samples.

## Office

A nextcloud with a `collabora` has `richdocuments`, and `nextcloud-office`, a oneshot in the container after
`nextcloud-setup`, has it open documents at the collabora's `url`, which browsers open and Nextcloud asks, and Collabora
call back to the nextcloud as the browser found it. The collabora accepts WOPI from the `url` of each nextcloud that
names it (`org/apps/collabora.nix`).

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

A nextcloud's state is its database and its users' files, in `<home>/nextcloud/data/<user>/files`, and is kept as long
as the app is: the database alone has shares, versions' and the trash's records, tags, comments, favorites, app
passwords and sessions. What it's made of is declared: its apps, its office, its realm and its external storages, which
the oneshots put back as they start.

- config.php's `secret`, with which Nextcloud encrypts what it keeps encrypted in the database, is the app's
  `secret-key`, which each unit that runs occ loads as a credential, and its `instanceid`, which names its appdata,
  `oc<id>`, the app's id as 8 hex digits: a database restored to a nextcloud installed anew reads as it did. A new
  `secret-key` makes what's encrypted with the old unreadable, app passwords among it; the oneshots put back their own.
- What's in the trash is deleted after 30 days, and a version after a year, the versions thinned meanwhile as Nextcloud
  does, `trashbin_retention_obligation` and `versions_retention_obligation`: Nextcloud's own default deletes only for
  room, which a user without a quota never runs out of.
- Its home is a principal's state (`docs/parts/state.md`): with `state.archives` it's archived with its database's dump
  in it, but for previews and each user's cache and uploads in progress, which `<home>/nextcloud/data/.resticignore`
  leaves out. A home on SMB is its server's to keep: an archive reads the home without what's mounted in it.

## Testing

`tests/nixos/nextcloud.nix` evaluates its apps, office, login, retention, secret and instanceid, and `vmTests.keycloak`
(`docs/parts/keycloak.md`) runs the login, the user of nextcloud's own it disables, and the apps it keeps.

## Migrating: Kompismoln/org's nextclouds to drive and drive-dev

Kompismoln/org's `nextcloud-kompismoln`, on helsinki, and `nextcloud-kompismoln-dev`, on stationary, become `drive`, at
`drive.kompismoln.se`, and `drive-dev`, at `drive-dev.kompismoln.se`, each with a database made anew. Their ids, and so
their uids, stay. A host changes only as it's applied, so stationary takes the org's branch alone first, and helsinki,
which runs the keycloak both log in with, after. Each host's homes are under `/srv/storage`, where an old one stays
after the switch that drops it. Run the host's commands as root, `o11n ssh service-rescue <host> --user root`.

### Before either

1. Have every user of either nextcloud a user in `kompismoln` of the same name, from `nextcloud-occ user:list` in each
   container: they log in as that, and an account nextcloud had before no longer can.
2. Point `drive-dev.kompismoln.se` at stationary in DNS, as `nextcloud-kompismoln-dev.kompismoln.se` is, for ACME.
3. Once o11n's drive is merged, on the org's branch, lock it, run o11n from it, make each app's identity and secrets,
   take out the old ones, and write the creation rules anew:

   ```sh
   nix flake update o11n
   o11n identity create app-drive
   o11n identity create app-drive-dev
   for id in app-drive app-drive-dev; do
     for key in $(o11n keys $id); do [[ $key == age-key ]] || o11n secret generate $id "$key"; done
   done
   git rm enc/app-nextcloud-kompismoln* public-keys/app-nextcloud-kompismoln*
   o11n sops-yaml '*' > .sops.yaml
   ```

   `o11n status app-drive app-drive-dev` then has their keys and secrets ok. Nothing applies them yet.

### drive-dev, on stationary

1. Keep what the old one has, to compare with, as it still runs:

   ```sh
   keep=/srv/storage/migration/drive-dev && mkdir -p $keep
   occ() { nixos-container run nextcloud-kompismoln-dev -- nextcloud-occ "$@"; }
   occ user:list --output=json >$keep/users.json
   occ share:list --output=json >$keep/shares.json
   systemctl start nextcloud-kompismoln-dev-pgsql-dump
   cp /var/lib/nextcloud-kompismoln-dev/dbdump.sql $keep/
   cd /var/lib/nextcloud-kompismoln-dev/nextcloud/data
   for user in */; do [[ -d $user/files ]] && echo "${user%/} $(find "$user/files" -type f | wc -l)"; done >$keep/files
   ```

2. drive-dev's client is helsinki's keycloak's, which isn't applied yet, so make it by hand: in the admin console's
   `kompismoln` realm, create the client `drive-dev`, with client authentication on and the standard flow alone, and the
   redirect URIs `https://drive-dev.kompismoln.se/apps/user_oidc/code` and
   `https://drive-dev.kompismoln.se/index.php/apps/user_oidc/code`, and store its secret, from its Credentials tab.
   `keycloak-realms` puts the declared client over it when helsinki is applied, with this secret:

   ```sh
   o11n secret generate app-drive-dev oidc-secret --from <(printf %s '<the client secret>')
   o11n apply stationary
   ```

   The apply makes its database and the role it's owned by, `drive-dev`, empty, before the container starts
   (`nixos/postgresql.nix`), and Nextcloud installs into it.

3. Once `nextcloud-oidc`, `nextcloud-office` and `nextcloud-apps` are active in `drive-dev`, copy each user's files and
   versions into it with the container stopped, but their trash, whose records are gone with the database:

   ```sh
   keep=/srv/storage/migration/drive-dev
   systemctl stop container@drive-dev
   old=/srv/storage/var/lib/nextcloud-kompismoln-dev/nextcloud/data
   for user in $(cut -d' ' -f1 $keep/files); do
     rsync -a --exclude=files_trashbin --exclude=cache --exclude=uploads $old/$user/ /var/lib/drive-dev/nextcloud/data/$user/
   done
   systemctl start container@drive-dev
   ```

   sverigesval-dev builds from rolf's `files/+pub` among them: `systemctl start sverigesval-dev-build`.

4. Have each user log in at `drive-dev.kompismoln.se`, which sends them to `kompismoln`; a desktop or phone client logs
   in anew. Then scan what they have, and compare with what the old one had:

   ```sh
   keep=/srv/storage/migration/drive-dev
   occ() { nixos-container run drive-dev -- nextcloud-occ "$@"; }
   occ files:scan --all
   cd /var/lib/drive-dev/nextcloud/data
   for user in */; do [[ -d $user/files ]] && echo "${user%/} $(find "$user/files" -type f | wc -l)"; done | diff $keep/files -
   occ user:list --info --output=json
   ```

   The files are as they were, and each user is user_oidc's. What `$keep/shares.json` has is lost with the database, as
   are tags, comments and favorites, for the users to share anew. Open a document to see the office, and see
   `o11n status app-drive-dev`.

### drive, on helsinki

1. Say when it's down, from the old one's apply to the users' logins.
2. Keep what the old one has as in drive-dev's 1, with `keep=/srv/storage/migration/drive` and `nextcloud-kompismoln`.
3. pelle lets drive in to `user-ami@pelle` and `user-alex@pelle` by its new sftp-key, and keeps its archive, so apply it
   first, then helsinki, whose keycloak makes `drive`'s client and puts `drive-dev`'s declared one over the one made by
   hand, and whose postgresql makes `drive`'s database and role:

   ```sh
   o11n apply pelle
   o11n apply helsinki
   ```

4. Copy the files as in drive-dev's 3, with `drive` and `/srv/storage/var/lib/nextcloud-kompismoln/nextcloud/data`, of
   the users without `homes` alone: lisa's, domenique's, ami's, chris's, alex's and johanna's are their storage box
   shares, which helsinki mounts at their data anew. Then `systemctl start sverigesval-build`.
5. Log in, scan and compare as in drive-dev's 4. Archive it once by hand, and `o11n status app-drive` has the archive,
   each home and each external storage, ami's `henrik` and alex's `lenovo`, ok:

   ```sh
   systemctl start state-archive@app-drive:pelle
   ```

### After both

Once nothing is missed, drop what the old ones left: their clients, `nextcloud-kompismoln` and
`nextcloud-kompismoln-dev`, in the admin console; their databases and roles,
`runuser -u postgres -- dropdb nextcloud-kompismoln` and `dropuser` on helsinki, and the dev's on stationary; and their
homes, `/srv/storage/var/lib/nextcloud-kompismoln` and `/srv/storage/var/lib/nextcloud-kompismoln-dev`, with the dumps
in them, once `/srv/storage/migration` is no longer needed either.

## Work in progress

- Nothing tells Keycloak's groups to nextcloud: it has no admin.
- A user's files are nextcloud's only once they've logged in, as user_oidc makes the user then; Nextcloud finds them as
  the user opens their folders, or as `nextcloud-occ files:scan <user>` scans them.
