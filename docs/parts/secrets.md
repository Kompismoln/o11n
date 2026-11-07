# Secrets

An entity's keys are part of the org: its `keys` (`org/entity.nix`) declare each with its type, its `secrets`
(`org/secrets.nix`) where they're kept, and `o11n` makes, stores, encrypts and rotates them (`crates/o11n/src/keys.rs`,
`crates/o11n/src/store.rs`, `crates/o11n/src/secrets.rs`, `crates/o11n/src/sops.rs`, `crates/o11n/src/host.rs`).

## Keys

An entity has the keys something reads, and no others: every entity an age-key; a user an ssh-key, which `o11n as` and
`o11n ssh` log in with; a principal a `passwd` with `principal.hasPasswd` and an `ssh-key` with
`principal.hasPublicKey`, as `nixos/org/principals.nix` reads them; service-rescue a `passwd` and an `ssh-key`,
service-locksmith and service-nix-remote an `ssh-key`. A host's `ssh-key` has a public key and no secret. What an org
holds of a key it no longer has stays in its sops file, as `o11n status`'s `secrets` and `o11n secret extra` tell, until
`o11n secret edit` takes it out, or `o11n secret rename <id> <old> <new>` moves it to a key the entity has, as after the
key's name changes with what it's named by: it stores and validates it as that key, writes its public key and removes
the old, for a key without slots.

A key's type says how it's generated and validated, and whether it has a public key, in `public-keys/`: each type has
<<<<<<< signed
one but `passphrase`, `luks` and `file`. A `luks` key has slots, as the luks device it opens does.
=======
one but `passphrase`, `luks` and `file`. A `luks` key has slots, as the luks device it opens does. An `ssh` key is
Ed25519 and an `ssh-rsa` key RSA, for what logs in with RSA alone, as nextcloud's SFTP does
(`docs/parts/allotments.md`).
>>>>>>> @stamp

## Where they're kept

- An entity's identity, its age-key, is its `identityFile`, `enc/<handle>.age`, encrypted to itself, its actors and the
  root identities.
- The rest is in its `sopsFile`, `enc/<handle>.yaml`, encrypted to itself, the root identities and its grants, as
  `o11n sops-yaml` gives them: a host's at the file's top, any other's under its name. Slot 0 of a key with slots is
  stored as the key, any other as `<key>--<slot>`, and a password's hash as `<key>-sha512`.
- A host keeps its identity at its `decryptionKey`, `/keys/<handle>`, with which sops-nix decrypts what its
  configuration reads (`nixos/org/sops.nix`).

`o11n reencrypt` encrypts each to its recipients as they are, and `o11n identity rotate` replaces the identity of an
entity but a host, and encrypts to the new one what was to the old.

## A host's keys

A host's identity and luks-key are the host's as much as the org's, so the host takes a new one through its locksmith:
service-locksmith's ssh-key logs in as `locksmith`, whose forced command is `nixos/services/locksmith.sh`
(`nixos/services/locksmith.nix`). `o11n host check` has it confirm a key, `o11n host push` take a new one and
`o11n host revoke` drop an old one, and the org stores the change once the host has made it. A host's ssh-key is its
own, and `o11n host pull-ssh-key` writes its public key.

### Rotation

A rotation keeps the host able to decrypt its secrets and to boot unattended between deploys, and the tools refuse its
steps out of order:

1. `o11n host push <host> age-key`, or `luks-key`
2. `o11n apply <host>`
3. `o11n host revoke <host> age-key`, or `luks-key --slot <slot>`

- An age-key: the host adds the new identity to those it has, and the org stores it and encrypts to it what was to the
  old. revoke has the host keep only the identity the org holds, and refuses until every sops file the running system
  and the one it boots next decrypt, as each lists them in `/etc/o11n/sops-files`, opens with it alone.
- A luks-key: the new one takes slot 0, which a deployment writes into the initrd (`nixos/disko.nix`), and the one it
  held moves to a free slot, so that either opens the disk. revoke refuses slot 0, and the luks-key in the initrd the
  host boots next; `o11n status`'s `initrd-key` tells when that's the new one.

`switch-system` installs the boot loader again after it switches, as the first install copies the initrd's secrets
before activation writes them, so that one apply puts the new luks-key in the initrd (`nixos/services/nix-switch.nix`).
