# Development

`dev/` holds what develops o11n rather than what o11n is: the checks, what writes the format and the stamps, the
operator's side and the agent's. Each runs from the clone's root, in the dev shell (`nix develop`), as a script of the
clone.

## Packages

`dev/` holds four scripts, `write.sh`, `check.sh`, `agent.sh` and `operator.sh`, and what's left of the work is
`o11n-dev`'s.

## Check

`dev/check.sh [stage]...` checks the stages named, or all of them, side by side, says what each said in order, and which
failed, and in a git checkout logs each to `dev/state/logs/<stage>.log`, and how it ended to
`dev/state/logs/<stage>.json`, which the hooks read:

- `stamps`, every conflict marker a stamp's
- `pending`, what is left to stamp
- `stamped`, each change to a doc since `STAMPED`, or else `o11n-dev base`, stamped, as `dev/write.sh` stamps it
- `format`, the Nix, the Rust and the docs that hold no stamps pending, as `dev/write.sh` writes them
- `lint`, statix, deadnix and shellcheck
- `docs`, the references of the docs (`o11n-dev refs check`)
- `parts`, that `dev/parts.toml` holds what it declares (`o11n-dev parts check`)
- `index`, that `docs/index/` is as `dev/write.sh index` writes it (`o11n-dev index check`)
- `eval`, `leaks` and `bats`, which build `.#stages.<stage>`
- `vm`, which builds `.#stages.vm` on the remote builder with the tree's own `o11n remote`.

All of them take ~60s, and ~240s when bats runs, as after a change to `tools/` or `dev/`. The flake's `stages.stamps`,
`stages.format` and `stages.lint` run the same stage in the sandbox (`tests/source.nix`). `o11n-dev files` gives
`dev/check.sh` and `dev/write.sh` the same files to read: what git tracks or would, or in a directory without git, as in
the sandbox, every file under it.

## Parts

`dev/parts.toml` declares the parts of o11n: each its stage, its layer, its doc, if it has one, and its code. A file is
the part's whose entry is closest to it, as `org/state.nix` is the state's within the org's `org/`, and no two parts'
entries for it are alike.

- `stages` names, in order, how far a part has come: felt, implied, mentioned, named, itemized, planned, drafted,
  solidified, cemented and protected.
- `layers` names the layers a part can be of: `domain`, `ux`, what an org's operator works with, `dx`, what o11n's
  developers work with, and `platform`, what o11n configures a kind of host on for what the domain says of it.

## Index

`docs/index/<part>.md` indexes a part's interface: for now the options of an org, each by its place in `org.toml`, its
type, its default and its description, under the part whose code declares it. The flake's `index` (`dev/index.nix`)
reads them from `org/context.nix`, evaluated for `tests/inventories/base`, which holds nothing: a default computed from
an entity's own config has a `defaultText`, as `lib.literalExpression` over the entity's options, the org's as
`org.<option>`, or as `lib.literalMD` where it draws on more, or the index fails to evaluate. `o11n-dev index write`
writes a doc for each part that has any, and removes the rest, as `dev/write.sh index` has it do. Each is a doc of the
part it indexes, and stamped like any other, so that a change to a part's interface is stamped.

## Write

`[STAMPED=<commit>] dev/write.sh [stage]...` writes what follows from the code and the docs for the stages named, or all
of them, in order, each what a stage of `dev/check.sh` checks:

- `format`, the Nix, the Rust and the docs that hold no stamps pending, which `format` checks
- `index`, `docs/index/` (`o11n-dev index write`), which `index` checks
- `stamps`, each change to a doc since `STAMPED` as stamps pending, against what the operator had signed of it there,
  which `stamped` checks; left out without `STAMPED`, unless named.

A failing `format` stage says to run it rather than nixfmt, rustfmt or prettier: prettier reads a stamp's markers as
Markdown and reflows them.

## Stamps

A stamp is a git conflict in a doc, from `<<<<<<< signed` to `=======` as the operator last signed it. `o11n-dev stamps`
writes them, flags a conflict marker that isn't a stamp's, and the stamps pending. The operator stamps them before work
proceeds.

The hooks write them against `o11n-dev base`: `refs/stamped/<branch>`, which `./dev/operator.sh stamp` sets, what the
operator last stamped. Until a branch has one, against the commit the turn started at, or else where the branch left the
main branch `settings.toml` names, so that what wasn't stamped is stamped again rather than left out.

## Operator

In the dev shell, pulling and pushing through `o11n as` as `user-$O11N_DEV`, `$O11N_DEV` a user's name such as `alice`:

```sh
./dev/operator.sh fetch [branch]    # switch to the branch, bring it and refs/stamped/* up to origin, say what is pending
./dev/operator.sh stamp [message]   # once nothing is pending: commit as "stamp", or the message, set refs/stamped/<branch>, push both, print the revision
./dev/operator.sh merge [branch]    # once nothing is pending and eval holds: squash onto main, push, delete the branch and its refs/stamped, print main's revision
```

`stamp` prints at once when nothing changed since it last stamped, as in `./dev/operator.sh stamp | osc copy`. Start the
next session at the revision it prints, with a first prompt that begins `At <revision>`.

## Agent

`./dev/agent.sh` runs as Claude Code's hooks (`.claude/settings.json`). Each says nothing unless the agent has something
to do, and exits 0 but `tool-end` and `turn-end`, which exit 2 to tell the agent.

`settings.toml` has, under `[hooks.<hook>]` for each hook that checks, the stages of `dev/check.sh` it refuses work for
(`refuse`) and tells of (`tell`) when they fail; `o11n-dev hook <hook> refuse|tell` reads them, and fails for a hook or
a key it doesn't know. `hand-over` checks once it has pushed, so it only tells.

- `session-start`, as a session starts: provisions a cloud container, then checks the commit the session starts at as
  `[hooks.session-start]` says.
- `turn-start`, as a turn starts: moves a fresh session to the commit its first prompt starts at, or fast-forwards to
  what the operator pushed, and checks what that moved it to as `[hooks.turn-start]` says.
- `tool-end`, after each Bash command: once the agent has commits no remote has, does what `turn-end` does, so that the
  turn ends with all pushed, as the environment's own Stop hook, which runs beside `turn-end`, expects.
- `turn-end`, as a turn ends: unless work was refused or the turn changed nothing, provisions a cloud container that
  isn't, runs `dev/write.sh` with `STAMPED` set to `o11n-dev base`, commits what that changed as `turn-end` and pushes.

Run at request "hand over":

- `hand-over`: writes as `turn-end` does, commits all as `hand-over` and pushes, then checks as `[hooks.hand-over]`
  says.

Outside the hooks, run `./dev/agent.sh` as they would: a prompt that starts `At <rev>` as `{"prompt": "At <rev>"}` on
turn-start's stdin, and source `dev/state/env` for the tools.

### Provisioning

In a cloud session, `session-start`:

- unshallows the clone
- fetches the `github:` and `gitlab:` inputs its `flake.lock` locks over git with `./dev/agent.sh fetch-inputs`, as the
  forges' archives are refused or rate-limited there; nix then finds them in the store under the same content hash
- writes the dev shell's PATH and `O11N_ROOT` to `dev/state/env`, for the hooks, and to `$CLAUDE_ENV_FILE`, for the
  session's commands
- roots the inputs and the dev shell in `dev/state/roots`, so that `nix store gc` keeps them
- with `O11N_REMOTE_BUILDER` set, says when the remote builder doesn't answer `o11n remote info`.

## Lix daemon

`./dev/agent.sh lix-daemon <dir>` starts Lix's daemon in the background as the remote builder runs it, on a store and
socket of its own in `<dir>` and for untrusted clients, and prints its store URL; stop it with
`kill "$(cat <dir>/pid)"`. Left to itself, Lix's daemon would listen on the socket the session's own nix takes for its
daemon, and give fixed-output fetches their network through pasta, which can't start in a cloud session.

## State

In `dev/state/`, out of git, which `rm -rf dev/state` resets:

- `env`: the dev shell's PATH and `O11N_ROOT`, which session-start writes for the hooks and the session's commands.
- `roots`: the gc roots of the inputs and the dev shell.
- `session-start`: what session-start hands the session's first turn.
- `turn-start`: the commit the turn started at, as in `STAMPED="$(cat dev/state/turn-start)" dev/write.sh`.
- `refused`: there while work is refused this turn.
- `logs/<stage>.log`: what `dev/check.sh` last said for the stage, under a line of when, at which commit and what ran
  it.
- `logs/<stage>.json`: how that check ended, `{"stage", "commit", "status"}`. A hook removes it before it checks, and
  takes a stage it's missing for as failed.

## Tests

`dev/test` holds the bats tests of `dev/`: `bats dev/test`, or `.#stages.bats` with those of `tools/`.
