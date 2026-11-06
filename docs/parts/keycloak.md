# Keycloak

An app with `keycloak` (`org/apps/keycloak.nix`) runs Keycloak at its endpoint, as the app, with its database in the
host's postgresql, dumped into the app's home as any other (`nixos/apps/keycloak.nix`, `docs/parts/state.md`).

## What the org keeps

The org keeps what couples Keycloak to the rest of it; Keycloak keeps the rest, its users and their credentials
included.

- Its `admin-client-secret` is the secret of the client `o11n`, an admin of every realm, which Keycloak bootstraps as it
  first starts, from a sops template, as it does nothing else: no admin password is the org's. A person administers
  Keycloak as a user of its own, and the host's root recovers one with `kc.sh bootstrap-admin user`.
- Each of its `realms` is a realm that `keycloak-realms`, a oneshot after Keycloak, logs in as `o11n` to keep as
  declared each time it runs: created when it's missing, and its settings put, with its display name. Registration is
  off, and a user can't rename their account, as an app matches a user by username; a user can reset their password.
- A realm mails as the app, which logs in to submission on `mail.<endpoint>` with its `mail` key, so an app with realms
  has `principal.mail = { inbox = true, send = true }`, or fails evaluation.
- `o11n`'s account has the app's address, where Keycloak sends a realm's test mail.
- An app whose kind derives a client, as jitsi does (`org/apps/jitsi.nix`), has it in the realm it names, of the
  keycloak it names, which keeps it as it keeps a realm: made when it's missing, and put over what it was, by its
  `clientId`, leaving what isn't declared of it be. The keycloak fails evaluation for a client in a realm it doesn't
  keep. Jitsi's is public, with PKCE, and redirects to its `/static/sso.html`, which its sign-in reads from the same
  client (`nixos/apps/jitsi.nix`).
- A confidential client has a secret, its app's `oidc-secret`, which the keycloak's host decrypts and puts as the
  client's. Nextcloud's is one, with `nextcloud.keycloak` and `nextcloud.realm` (`org/apps/nextcloud.nix`).

## Nextcloud

A nextcloud with a `keycloak` has `user_oidc`, and `nextcloud-oidc`, a oneshot in its container after `nextcloud-setup`,
keeps the realm as its provider, named by the realm's display name, with the app's `oidc-secret` from a file bound into
the container (`nixos/apps/nextcloud.nix`). A Keycloak user is the nextcloud user of the same name: user_oidc maps the
uid from `preferred_username`, as it is, and its soft auto-provisioning has a login of an account nextcloud had before
the account's, its files and all, with the name and address Keycloak has. The realm lets no one register or rename their
account, which is what keeps one from taking another's. Nextcloud's own logins go on beside, and user_oidc asks for
https.

## Status

`o11n status` (`docs/parts/o11n.md`) has `keycloak-mail <realm>` for each realm of an app that sends: logged in as
`o11n` with the app's `admin-client-secret`, Keycloak sends the realm's test mail, with the realm's own settings, to the
app's own inbox, and the check fails with what Keycloak says when it can't (`crates/o11n/src/keycloak.rs`).

## Testing

`vmTests.keycloak` (`tests/vm/keycloak.nix`) runs `tests/inventories/mail`'s `auth` on `web`, beside its mail server on
`mx`: Keycloak bootstraps `o11n` alone, keeps the realm as declared, and `meet`'s client, a jitsi on no host, which it
puts back as declared after it's changed by hand, and `cloud`'s, a nextcloud on `web` too, with its secret: alice, an
account of nextcloud's own, logs in with the realm as herself. `o11n status` has Keycloak mail the app over verified
TLS, and fail with what Keycloak says when the server is down.

## Setting up: Kompismoln/org's keycloak as auth.kompismoln.se

Kompismoln/org's keycloak was set up by hand, with the admin password `initialAdminPassword` gave it and since changed,
and the realm `jitsi-realm`, which jitsi's client is in and which o11n doesn't keep.

1. Archive its state to pelle daily, and have it send mail, as it tells of a failed archive, under `[app.keycloak]` in
   `org.toml`, as `docs/parts/state.md` does for klimatkalendern:

   ```toml
   principal.mail.send = true
   principal.state.archives.pelle.schedule = "daily"
   principal.state.archives.pelle.prune = { keep-daily = 7, keep-weekly = 5, keep-monthly = 12, keep-yearly = 1 }
   ```

   ```sh
   o11n secret generate app-keycloak archive-passwd
   o11n secret generate app-keycloak restic-key
   o11n secret generate app-keycloak mail
   o11n apply pelle
   o11n apply helsinki
   o11n ssh service-rescue helsinki --user root systemctl start state-archive@app-keycloak:pelle
   ```

2. Move it to `auth.kompismoln.se`, which DNS is to point at helsinki first, as ACME asks for its certificate there,
   give it an inbox at `auth@kompismoln.se`, and the realm `kompismoln`:

   ```toml
   endpoint = "auth.kompismoln.se"
   principal.mail = { inbox = true, send = true, address = "auth@kompismoln.se" }
   keycloak.realms.kompismoln = { displayName = "Kompismoln" }
   ```

   The issuer moves with it: jitsi's sign-in follows, and everyone signed in signs in again.

3. Keycloak bootstraps `o11n` only on a new install, so make it by hand once: in the admin console's `master` realm,
   create the client `o11n`, with client authentication and service account roles on and the standard flow off, assign
   its service account the realm role `admin`, and store its secret, from its Credentials tab:

   ```sh
   o11n secret generate app-keycloak admin-client-secret --from <(printf %s '<the client secret>')
   o11n apply helsinki
   ```

4. See that it archives and mails: `o11n status app-keycloak` has `archive pelle helsinki` and
   `keycloak-mail kompismoln`.

5. Move jitsi into `kompismoln`, as `jitsi = { keycloak = "keycloak", realm = "kompismoln" }`, and apply helsinki:
   `keycloak-realms` puts jitsi's client over the one `kompismoln` had, and jitsi's sign-in moves with it. Then move the
   friends' accounts out of `jitsi-realm`, or invite them anew, and delete it in the admin console.

6. Have each nextcloud's users log in with `kompismoln`, under `[app.nextcloud-kompismoln]` and
   `[app.nextcloud-kompismoln-dev]`:

   ```toml
   nextcloud.keycloak = "keycloak"
   nextcloud.realm = "kompismoln"
   ```

   ```sh
   o11n secret generate app-nextcloud-kompismoln oidc-secret
   o11n secret generate app-nextcloud-kompismoln-dev oidc-secret
   o11n apply helsinki
   o11n apply stationary
   ```

   helsinki, the keycloak's host, decrypts the dev's secret too, as the app-scheduler it grants. Make each user in
   `kompismoln` with the name nextcloud has for them, from `nextcloud-occ user:list` in the container, and they log in
   to their own account with "Log in with Kompismoln"; try it on the dev first.

## Work in progress

- That the keycloak's host can decrypt a confidential client's secret isn't known at evaluation: one that can't fails as
  sops-nix decrypts.
- Nothing maps Keycloak's groups to nextcloud's.
- A realm or client the org no longer declares stays in Keycloak until someone removes it.
- `keycloak-realms` keeps what's declared, and leaves what isn't as it finds it: a setting taken out of the declaration
  stays as it was last put.
- Nothing makes its database or the role it logs in as, which `nixos/postgresql.nix` leaves to the operator.
- The bootstrapped `o11n` is a temporary admin to Keycloak, which its console says.
