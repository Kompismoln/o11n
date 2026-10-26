# Agent instructions

This document contains project-wide instructions written by humans for agents.

## Environment

`.claude/hooks/session-start.sh` prepares a session: it fetches the github: inputs over git, puts nixfmt, statix,
deadnix, shellcheck and the tools' dependencies on PATH, and unshallows the clone. Its fetches and tools are rooted in
`/nix/var/nix/gcroots/claude-session`, so `nix store gc` keeps them. The hook runs only in a session that starts in the
clone. Otherwise run `CLAUDE_PROJECT_DIR=$PWD .claude/hooks/session-start.sh` from the clone; without `CLAUDE_ENV_FILE`
it doesn't put the tools on PATH.

- An org's `org.toml` is its source of truth, and `org/` reads it.
- Archeology is not allowed unless said otherwise, the commit given has all you need.

- Downloads of GitHub archives, which `github:` inputs use, are refused with HTTP 403; git over https works. Fetch the
  same revisions over git once, and plain `nix` commands work for the rest of the session, because the inputs are then
  in the store under the same content hash. The hook does this with `dev/fetch-github-inputs.sh`, which takes another
  flake's lock as well: `dev/fetch-github-inputs.sh <org clone>/flake.lock`.

- Without the hook the clone is shallow. When referring to it as `git+file://`, for example to check a single commit,
  add `shallow=1`: `nix flake check "git+file://$PWD?rev=$(git rev-parse HEAD)&shallow=1"`.

- Instead of `/dev/kvm`, NixOS VM tests can run on the `O11N_REMOTE_BUILDER` when set, and its host allowed by the
  session's network policy, `tools/bin/nix-remote.sh build <installable>` builds them on a host with the remote-builder
  role, and `nix-remote.sh check` builds every check there.

- An org's private `git+ssh` inputs can't be fetched. Override them with stub flakes
  (`--override-input <input> path:<stub>`) that have the attributes the org reads. Kompismoln/org keeps its stubs in
  `tests/stubs`, and `tests/stubs/with-stubs.sh <command>` appends the overrides to a `nix` or `nix-remote.sh`
  command. Fetch the org's `github:` inputs over git first, as above.
- Kompismoln/org's devShell takes `o11n.packages.<system>.o11n-tools` and exports `O11N_ORG_ROOT=$PWD`, which the
  wrapper only defaults to `/etc/nix/inputs/self`. To try changes to the tools on the org, `O11N_TOOLS=<o11n
  clone>/tools` puts the clone's `bin/` first on its PATH.
- Nix runs in single-user mode on this session's `/nix`. Point any other daemon, such as Lix's, at its own store with
  `NIX_REMOTE="local?root=<dir>"` (Lix's `nix-daemon` ignored `--store`).
- Lix gives fixed-output fetches their network through pasta, which can't start in this sandbox; set `pasta-path =`
  (empty) for a test daemon here.
- A fixed-output fetch from a GitHub archive URL fails here too. Fetch the same revision over git into a directory named
  `source`, remove `.git`, and add it with `nix-store --add-fixed --recursive sha256 <dir>/source`; it lands at the path
  the fetch would have produced.
- `pkill -f <pattern>` can match the command line of the shell running it. Kill by PID.
- Don't evaluate every host of an org here, as Kompismoln/org's `stages.systems` does: ~11 GB and minutes, and more
  with its homes. That belongs on the remote builder: `nix-remote.sh eval systems [o11n revision]` from the org's
  clone, once it runs there (`agents/wip-remote-evaluation.md`).

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

## Workflow

The workflow spans over a session, starts from a human-reviewed commit and ends with a handover. A session is turns,
each from a human's message to where the agent stops.

### 1. Before work starts

Run `nix build .#stages.baseline`: on non-zero exit, pause work and relay the flags.

### 2. At a turn's start

A message that names a commit (`At <rev>`) starts the turn there: fetch the branch and fast-forward to it, or merge it
in when the branch has commits of the agent's it doesn't. A human's commit since, such as a stamp, is then where the
next stamps count from, and a push isn't refused for it.

### 3. Between units of work

Use your own judgement and the tests and checks at your disposal (see "Tests and checks"). Commit and push as you see
fit; neither is a handover.

### 4. At a turn's end

`.claude/hooks/stop.sh` runs `stamps check`, which fails while the docs that changed since a human last signed have no
stamps: write them with `nix run .#write-stamps` and commit what it writes. A session's hooks may ask for a commit and
a push as well.

### 5. Handing over

When asked for a handover or pull request:

1. Remove all comments that don't pass "Comments" in the files the change touches, pre-existing included.
2. Run `nix flake check` and relay the flags.
3. Commit, run `nix run .#write-stamps` and commit what it writes, then push.

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

The handover check is `nix flake check`. It takes about a minute when only evaluation is to be redone, and about three
more when bats runs, as after a change to `tools/`, `dev/` or `scripts/`.

### Stages

`nix build .#stages.<name>` builds one category of the checks, those named `<name>` or `<name>-*`:

- `baseline`: what a human settles before work proceeds: `stamps check --baseline`, which fails on stamps pending, for
  now
- `stamps`: `stamps check` over every Markdown file, which fails on a conflict marker that isn't a stamp's and flags
  stamps pending, ~2s
- `lint`: nixfmt, statix and deadnix over all Nix, and shellcheck over all shell, from `tools/` for `tools/`, where
  `.shellcheckrc` applies, ~10s
- `eval`: `tests/nixos/*.nix` and each inventory's `tests.nix`, evaluation tests, and every inventory home's
  `activationPackage`, ~40s
- `leaks`: each inventory host's build plan checked for org names, and the rescue stick's for secrets
  (`tests/leaks.py`), ~90s
- `bats`: `tools/test`, `dev/test` and `scripts/test`, ~3 minutes
- `vm`: the VM tests, which aren't checks (see "VM")

Between units of work, by what changed: docs, `stamps`; Nix, `lint` and `eval`, and `leaks` for what hosts run;
`tools/`, `dev/` or `scripts/`, `lint` and `bats`; what a module does on a host, its VM test.

### Bats

- `bats tools/test dev/test scripts/test` runs them outside the sandbox, with the tools the session hook puts on
  PATH, ~3 minutes.
- `tools/test` copies `tools/` for each test and stubs `ssh`, `ssh-keyscan`, `cryptsetup` and `find-route.sh`; the
  `ssh` stub runs `nixos/org/locksmith.sh` for the locksmith.

### VM

VM tests live in `tests/vm/` and are exposed as `vmTests.<name>`, not as checks: they need KVM. Run them with
`tools/bin/nix-remote.sh build .#vmTests.<name>`, or all of them with `.#stages.vm`.

### Inventories

- `base`: an org with nothing in it.
- `principals`: one host with the inference-server and app-scheduler roles, and an app that imports a module from an
  input. The tests pass an inventory's `inputs.nix`, if it has one, as its `inputs`.
- `sample`: a cluster meant to use every role. It has `gw` (wg0 gateway and DNS, rescue mode, grub) and `web`, both with
  the nixos, peer and server roles, and an admin user with a cinnamon-office home on `web`.

Evaluate inventories with `o11nLib.fromInventory { path; inputs ? { }; }`.

### An org

An org's own expectations live in that org's checks, not here. A real org is read with `fromFlake`.

`scripts/check-org.sh`, with `ORG` set to an org's clone, builds that org's `eval` stage with this tree as its o11n;
nothing else runs it. Here, Kompismoln/org needs its stubs for that:
`tests/stubs/with-stubs.sh nix build .#stages.eval --override-input o11n git+file://<clone>` from the org.

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

## Documentation

`nix run .#write-stamps` inserts git conflict markers between the latest commit a human made and now, and a human
stamps them for the next baseline to pass.

- The primary document is `docs/o11n.md`: If a contradiction to it is discovered, stop, describe the landscape and
  provide options.
- Placeholder usernames in docs and tests are alice, bob, carol..., or semantic names (archive, guest, nobody, other,
  collaborator-one, admin).
- Docs refer to the code, and comments don't refer to the docs.
- Don't reference branch commits: they'll be squashed.

## Comments

- A) Every line of comment imposes a readability tax.
- B) A future reader can be saved work by knowing about non-evident details.
- ∟ When B is considerable enough to offset A, a comment is justified.

1. Prefix with the comment's nature
2. Tell what's non-evident and only what the code doesn't already tell
