# Org

## Ids

An entity's `id` is its class's alone, as its uid, its class's block plus its id, and its addresses derive from it: two
of a class with the same id, or an entity with a principal but no id, fail evaluation (`org/entity.nix`,
`org/principal.nix`). Another class's entity can have the same id. `o11n next-id <class>` prints the lowest id from 1 up
that none of the class has; some of Kompismoln/org's entities have 0, which stays theirs.

## Apps

An app's `kind`, one of o11n's (`org/types.nix`), gives it its kind's options, `org/apps/<kind>.nix`, beside its own
(`org/app.nix`), and its kind's configuration, `nixos/apps/<kind>.nix`; an app without one has its `configurationFile`
alone. Its kind is read from `org.toml` as it's written, as the options an app has can't depend on its config: an app
with a kind o11n has none of, or an option its kind doesn't have, fails evaluation.

```toml
[app.drive]
kind = "drive"
endpoint = "drive.example.com"
run-on-hosts = ["web"]
keycloak = "auth"
realm = "example"
roots.alice = "store-alice"
```

## Stores

A store is what the org keeps outside of its hosts. One with `smb`, a share on an SMB server, logs in to it as its
`login` with its `smb-password`, which it has while it has `smb` and grants to the hosts that mount it
(`org/store.nix`): a drive's or a photos app's roots each name a store, and are a directory of its share
(`docs/parts/drive.md`).

```toml
[store.alice]
smb = { host = "box.example.com", share = "alice", login = "alice" }
grants = ["host-web"]
```
