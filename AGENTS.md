# Agent instructions

## Environment

`docs/dev.md` details `dev/`: the checks, the stamps, the operator's side, and the agent's hooks, which provision a
cloud session. A session's first prompt names the commit it starts at, `At <rev>`. Where the hooks don't run, run
`./dev/agent.sh` as they would (`docs/dev.md`, "Agent").

- An org's `org.toml` is its source of truth, and `org/` reads it.
- Archeology is not allowed unless said otherwise, the commit given has all you need.

- The archives `github:` and `gitlab:` inputs download are refused (HTTP 403) or rate-limited (HTTP 429); git over https
  works. session-start fetches the inputs over git, so plain `nix` finds them in the store. For another lock, run
  `dev/fetch-inputs.sh <flake.lock>`.

- Instead of `/dev/kvm`, NixOS VM tests can run on the `O11N_REMOTE_BUILDER` when set, and its host allowed by the
  session's network policy, `tools/bin/nix-remote.sh build <installable>` builds them on a host with the remote-builder
  role, and `nix-remote.sh check` builds every check there. session-start says so when that host doesn't answer.

- An org's private `git+ssh` inputs can't be fetched. Override them with stub flakes
  (`--override-input <input> path:<stub>`) that have the attributes the org reads. Kompismoln/org's `tests/stubs` holds
  them, and `tests/stubs/with-stubs.sh <command>` appends the overrides to a `nix` or `nix-remote.sh` command.
- Kompismoln/org's devShell takes `o11n.packages.<system>.o11n-tools` and exports `O11N_ORG_ROOT=$PWD`, which the
  wrapper only defaults to `/etc/nix/inputs/self`. To try changes to the tools on the org,
  `O11N_TOOLS=<o11n clone>/tools` puts the clone's `bin/` first on its PATH.
- Nix runs in single-user mode on this session's `/nix`. For a Lix daemon, as the remote builder runs, use
  `dev/lix-daemon.sh` (`docs/dev.md`, "Lix daemon").
- A fixed-output fetch from a GitHub archive URL fails here too. Fetch the same revision over git into a directory named
  `source`, remove `.git`, and add it with `nix-store --add-fixed --recursive sha256 <dir>/source`; it lands at the path
  the fetch would have produced.
- `pkill -f <pattern>` can match the command line of the shell running it. Kill by PID.
- Don't evaluate every host of an org here, as Kompismoln/org's `stages.systems` does: ~11 GB and minutes, and more with
  its homes. That belongs on the remote builder: `nix-remote.sh eval systems [o11n revision]` from the org's clone, once
  it runs there (`agents/wip-remote-evaluation.md`).

### Pitfalls

- `builtins.pathExists drv.outPath` builds the derivation during evaluation.
- `exportReferencesGraph` on a `.drv` also requires every output it refers to, so it can't read a build plan without
<<<<<<< signed
  building it; read the `.drv` files instead, as `tests/leaks.py` does.
=======
  building it; read the `.drv` files instead, as `tests/leaks.sh` does.
>>>>>>> @stamp
- When searching store contents for short names, match whole words: store hashes can contain them (`ahbk` is valid
  base32).
- `nix flake check` stops at the first error; `--keep-going` shows them all.
- `nix flake check --no-build` fails with "path … is not valid" when a source it would copy isn't in the store yet; run
  once without it.

- `types.anything` merges a function by wrapping it in one without formal arguments, so a module that passes through it
  no longer gets `pkgs` or anything else from `_module.args`. Keep flake outputs in `types.raw`.
- `nix-remote.sh build --dry-run` answers "don't know how to build these paths": nothing has copied the `.drv` files to
  the builder yet.

## Workflow

When asked to hand over:

1. Remove all comments that don't pass "Comments" in the files the change touches, pre-existing included.
2. Run `./dev/agent.sh hand-over`.

All `./dev/agent.sh` commands are silent on success or print instructions for you to act on.

## Handling errors and warnings

How to handle a warning or error, in order of preference:

### 0. Ignore

Consider not handling an error or warning if:

- it's out of scope of the current task
- its timing, fallout and message are already about right

### 1. Fail at evaluation

If it's an error at build, switch or runtime on a host that could have been known when the org is evaluated:

1. write an assertion that fails evaluation and says what in the org to change
2. should it occur on a host anyway, make its message name the assertion that let it through

### 2. Raw writes to stderr and/or edges

These are for developers and ops, so:

- minimize tampering with the message
- maximize simplicity in handling

`try` in `tools/libexec/run-with.bash` does both: it dies with the command's own stderr.

## Tests and checks

`dev/check.sh` checks everything, ~60s and ~240s when bats runs (`docs/dev.md`, "Check").

### Bats

- `bats tools/test dev/test` runs them outside the sandbox, with the dev shell's tools, ~3 minutes.
- `tools/test` copies `tools/` for each test and stubs `ssh`, `ssh-keyscan`, `cryptsetup` and `find-route.sh`; the `ssh`
  stub runs `nixos/org/locksmith.sh` for the locksmith.

### VM

VM tests live in `tests/vm/` and are exposed as `vmTests.<name>`, not as checks: they need KVM. Run them with
`tools/bin/nix-remote.sh build .#vmTests.<name>`, or all of them with `dev/check.sh vm`.

### Inventories

- `base`: an org with nothing in it.
- `principals`: one host with the inference-server and app-scheduler roles, and an app that imports a module from an
  input. The tests pass an inventory's `inputs.nix`, if it has one, as its `inputs`.
- `sample`: a cluster meant to use every role. It has `gw` (wg0 gateway and DNS, rescue mode, grub) and `web`, both with
  the nixos, peer and server roles, and an admin user with a cinnamon-office home on `web`.

Evaluate inventories with `o11nLib.fromInventory { path; inputs ? { }; }`.

### An org

An org's own expectations live in that org's checks, not here. A real org is read with `fromFlake`.

`./dev/operator.sh check-org`, with `ORG` set to an org's clone, builds that org's `eval` stage with this tree as its
o11n; nothing else runs it. Here, Kompismoln/org needs its stubs for that:

`tests/stubs/with-stubs.sh nix build .#stages.eval --override-input o11n git+file://<clone>` from the org.

To see whether a change alters an org's systems, evaluate each host's `config.system.build.toplevel.drvPath` with
`--override-input o11n "git+file://<clone>?rev=<rev>&shallow=1"` at the old and the new revision: equal paths are equal
systems. Keep the org's tree as it is meanwhile: hosts with the peer role carry the org's source
(`/etc/nix/inputs/self`), so a change to any file git tracks there changes them.

### Keys and secrets

Use `generate-keys.sh` with the org tooling in `tools/bin`.

- `keys/root-1` is a committed throwaway root identity. With `SOPS_AGE_KEY_FILE=keys/root-1`, `sops decrypt enc/<file>`
  shows any secret.
<<<<<<< signed
- To add an entity, declare it in `org.toml`, then from the inventory directory run
  `id-entities.sh -<class> <name> init` and `id-entities.sh -<class> <name> new <key>` for each key the configuration
  reads, as `generate-keys.sh` does. Create hosts before what is granted to them: they have to exist to be recipients.
- The tools need age, jq, mkpasswd, nix, openssl, sops, ssh-keygen, toml2json, wg and envsubst on PATH.
  `nix build .#nixpkgs.legacyPackages.x86_64-linux.<package>` gives each from o11n's own nixpkgs.
=======
- To add an entity, declare it in `org.toml`, then from the inventory directory, with `O11N_EXPORT` naming the
  inventory's export as `generate-keys.sh` writes it, run `id-entities.sh -<class> <name> init` and
  `id-entities.sh -<class> <name> new <key>` for each key the configuration reads, as `generate-keys.sh` does. Create hosts before what is granted to them: they have to exist to be recipients.
- The tools need age, jq, mkpasswd, nix, o11n, openssl, sops, ssh-keygen and wg on PATH. `nix build .#o11n` gives
  o11n, and `nix build .#nixpkgs.legacyPackages.x86_64-linux.<package>` each of the others from o11n's own nixpkgs.
>>>>>>> @stamp
- In tests, compare with the files on disk (`builtins.readFile ./public-keys/...`) rather than with values computed by
  the same o11n code that is under test.

## Documentation

turn-end and hand-over stamp each change to a doc since what the operator last stamped (`docs/dev.md`, "Stamps"), and
the operator stamps them before work proceeds.

- The primary document is `docs/o11n.md`: If a contradiction to it is discovered, stop, describe the landscape and
  provide options.
- Placeholder usernames in docs and tests are alice, bob, carol..., or semantic names (archive, guest, nobody, other,
  collaborator-one, admin).
- Docs refer to the code, and comments don't refer to the docs.

## Comments

- A) Every line of comment imposes a readability tax.
- B) A future reader can be saved work by knowing about non-evident details.
- ∟ When B is considerable enough to offset A, a comment is justified.

1. Prefix with the comment's nature
2. Tell what's non-evident and only what the code doesn't already tell

Before a hand-over, remove the comments that don't pass this from the files the change touches, pre-existing included.
