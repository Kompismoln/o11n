# Agent instructions

This document contains project-wide instructions written by humans for agents.

## o11n basics

- o11n is a library that takes an `org` and returns NixOS, home-manager and disko configurations.
- An `org` must contain a root-level `org.toml` and calls `o11n.fromFlake self` to get its configurations.
- o11n has no `org` of its own, so it is tested against sample `org`s in `tests/inventories/`.
- An `org`'s own expectations live in that `org`'s checks, not here.

## Environment

`.claude/hooks/session-start.sh` prepares a session: it fetches the github: inputs over git, puts nixfmt, statix,
deadnix, shellcheck and the tools' dependencies on PATH, and unshallows the clone. Its fetches and tools are rooted in
`/nix/var/nix/gcroots/claude-session`, so `nix store gc` keeps them. The hook runs only in a session that starts in the
clone. Otherwise run `CLAUDE_PROJECT_DIR=$PWD .claude/hooks/session-start.sh` from the clone; without `CLAUDE_ENV_FILE`
it doesn't put the tools on PATH.

- Downloads of GitHub archives, which `github:` inputs use, are refused with HTTP 403; git over https works. Fetch the
  same revisions over git once, and plain `nix` commands work for the rest of the session, because the inputs are then
  in the store under the same content hash. The hook does this; by hand:

  ```sh
  python3 - flake.lock /tmp/flake.git.lock <<'EOF'
  import json, sys
  lock = json.load(open(sys.argv[1]))
  for node in lock["nodes"].values():
      locked = node.get("locked", {})
      if locked.get("type") == "github":
          node["locked"] = {
              "type": "git",
              "url": f"https://github.com/{locked['owner']}/{locked['repo']}",
              "rev": locked["rev"],
              "narHash": locked["narHash"],
              "lastModified": locked["lastModified"],
              "shallow": True,
          }
  json.dump(lock, open(sys.argv[2], "w"))
  EOF
  nix flake archive --reference-lock-file /tmp/flake.git.lock --no-write-lock-file
  ```

- Without the hook the clone is shallow. When referring to it as `git+file://`, for example to check a single commit,
  add `shallow=1`: `nix flake check "git+file://$PWD?rev=$(git rev-parse HEAD)&shallow=1"`.

- Instead of `/dev/kvm`, NixOS VM tests can run on the `O11N_REMOTE_BUILDER` when set, and its host allowed by the
  session's network policy, `tools/bin/nix-remote.sh build <installable>` builds them on a host with the remote-builder
  role, and `nix-remote.sh check` builds every check there.

- An org's private `git+ssh` inputs can't be fetched. Override them with stub flakes
  (`--override-input <input> path:<stub>`) that have the attributes the org reads. Kompismoln/org keeps its stubs in
  `tests/stubs`, and `tests/stubs/with-stubs.sh <command>` appends the overrides to a `nix` or `nix-remote.sh`
  command. Fetch the org's `github:` inputs over git first, as above, from the org's `flake.lock`.
- Nix runs in single-user mode on this session's `/nix`. Point any other daemon, such as Lix's, at its own store with
  `NIX_REMOTE="local?root=<dir>"` (Lix's `nix-daemon` ignored `--store`).
- Lix gives fixed-output fetches their network through pasta, which can't start in this sandbox; set `pasta-path =`
  (empty) for a test daemon here.
- A fixed-output fetch from a GitHub archive URL fails here too. Fetch the same revision over git into a directory named
  `source`, remove `.git`, and add it with `nix-store --add-fixed --recursive sha256 <dir>/source`; it lands at the path
  the fetch would have produced.
- `pkill -f <pattern>` can match the command line of the shell running it. Kill by PID.

### Pitfalls

- `builtins.pathExists drv.outPath` builds the derivation during evaluation.
- `exportReferencesGraph` on a `.drv` also requires every output it refers to, so it can't read a build plan without
  building it; read the `.drv` files instead, as `tests/leaks.py` does.
- When searching store contents for short names, match whole words: store hashes can contain them (`ahbk` is valid
  base32).
- `nix flake check` stops at the first error; `--keep-going` shows them all.
- `nix flake check --no-build` fails with "path … is not valid" when a source it would copy isn't in the store yet; run
  once without it.

- `types.anything` merges a function by wrapping it in one without formal arguments, so a module that passes through it
  no longer gets `pkgs` or anything else from `_module.args`. Keep flake outputs in `types.raw`.
- `nix-remote.sh build --dry-run` answers "don't know how to build these paths": nothing has copied the `.drv` files to
  the builder yet.

## Tests

Baseline is `nix flake check`.

### Inventories

- `base`: an org with nothing in it.
- `principals`: one host with the inference-server and app-scheduler roles, and an app that imports a module from an
  input. The tests pass an inventory's `inputs.nix`, if it has one, as its `inputs`.
- `sample`: a cluster meant to use every role. It has `gw` (wg0 gateway and DNS, rescue mode, grub) and `web`, both with
  the nixos, peer and server roles, and an admin user.

Evaluate inventories with `o11nLib.fromInventory { path; inputs ? { }; }`.

A real org, read with `fromFlake`.

To see whether a change alters an org's systems, evaluate each host's `config.system.build.toplevel.drvPath` with
`--override-input o11n "git+file://<clone>?rev=<rev>&shallow=1"` at the old and the new revision: equal paths are equal
systems. Keep the org's tree as it is meanwhile: hosts with the peer role carry the org's source
(`/etc/nix/inputs/self`), so a change to any file git tracks there changes them.

### Keys and secrets

Use `generate-keys.sh` with the org tooling in `tools/bin`.

- `keys/root-1` is a committed throwaway root identity. With `SOPS_AGE_KEY_FILE=keys/root-1`, `sops decrypt enc/<file>`
  shows any secret.
- To add an entity, declare it in `org.toml`, then from the inventory directory run
  `id-entities.sh -<class> <name> init` and `id-entities.sh -<class> <name> new <key>` for each key the configuration
  reads, as `generate-keys.sh` does. Create hosts before what is granted to them: they have to exist to be recipients.
- The tools need age, jq, mkpasswd, nix, openssl, sops, ssh-keygen, toml2json, wg and envsubst on PATH.
  `nix build .#nixpkgs.legacyPackages.x86_64-linux.<package>` gives each from o11n's own nixpkgs.
- In tests, compare with the files on disk (`builtins.readFile ./public-keys/...`) rather than with values computed by
  the same o11n code that is under test.

## Documentation rules

### 1. Humans write, agents suggest.

In all docs except `agents/*`, agents are only allowed to insert suggestions.

A suggestion is inserted as a fenced code-block immediately above the subject to change. The backticks are part of the
template, use 4 backticks as envelope if the suggestion contains a code-block. Prefer whole lines for new content.

```
AGENT: <verb>
<short explanation>
---
<optional suggestion for new content>
```

### 2. Docs refer to the code, the code speaks for itself.

The primary document is `docs/o11n.md`: If a contradiction to it is discovered, stop and prompt a resolution.

Before committing, remove all and any docstrings and comments that:

- reference the docs
- tell what the code does

### 3. When and how to write a comment.

- A) Every line of comment imposes a readability tax.
- B) A future reader can be saved work by knowing about non-evident details.
- A comment is justified when B is considerable enough to offset A.

### 4. Don't reference branch commits

They'll be squashed.

## Good to know (subject to change)

No org names, hosts, domains or namespaces in o11n: take them from `org`, or from `org.toml` in the tools. The host
checks enforce this for code the inventories use. The remaining hardcoding is in modules that no role imports:
`nixos/org/monitor.nix`, `nixos/monitor-node.nix`, `nixos/backup.nix` and `nixos/glesys-updaterecord.nix`.

- `tools/*` (aka km-tools) are duplicated in both o11n and orgs, some commands belong with the orgs (the bins) and
  others with o11n (remote).
- A table for every entity class, even when empty (`[app]`, `[store]`, ...). Without one, evaluation fails deep in
  `org/types.nix` and `org-toml.sh` queries fail.
- `[mailserver]` when any host has the server role: `nixos/org/sendmail.nix` reads it.
- `[flake]` when any host has the peer role: `nixos/org/nix.nix` reads it.
- An `endpoint` on the gateway of each vpn.

- For each NixOS host, a `facter.json` (`{"version":1,"system":"x86_64-linux"}` is enough in tests) or
  `hardwareReport = "standard"` and a configuration that sets `nixpkgs.hostPlatform` (a `hardware-configuration.nix`
  does), a root file system, and a way for root or a wheel user to log in; NixOS rejects a system without them.

- o11n's `boot` enables a bootloader on every host, systemd-boot by default: a configuration that enables grub needs
  `boot = "grub"`, and one without a bootloader turns both off with `lib.mkForce`.
- Every user, service and app needs an `ssh-key` public key unless `principal.hasPublicKey = false`, and every user a
  `passwd-sha512` secret unless `principal.hasPasswd = false`. A missing public key fails evaluation; a missing secret
  fails sops-nix's manifest check when the system builds.

- Services without an `id` get no user, but their public keys can still be read (rescue, nix-serve).

## Style

- Format Nix with nixfmt and lint it with statix and deadnix. statix has existing warnings in `nixos/`; keep new code
  free of them. Shell scripts in `tools/` pass shellcheck run from `tools/`, where `.shellcheckrc` applies (the km-tools
  package runs it on `bin/` and `libexec/`).
- Commits: `<area>: <what changed>`, lowercase, with a body that says why. Each commit passes the checks on its own.
- `tools/` is also copied into Kompismoln/org, and the copies have drifted. Hosts get o11n's copy through km-tools;
  operators run the org's copy.
