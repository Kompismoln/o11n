# Development

`dev/` holds what develops o11n rather than what o11n is: the checks, what writes the format and the stamps, the
operator's side and the agent's. Each runs from the clone's root, in the dev shell (`nix develop`), as a script of the
clone.

## Packages

Each script of `dev/` is a package as well (`packages/dev.nix`): `agent`, `check`, `write`, `stamps`, `operator`,
`fetch-inputs` and `lix-daemon`, each with what it runs. They're not in the dev shell: it has what each package the
flake builds runs, read from the package's `runtimeInputs`, so that the scripts run there as they are, and bats for
their tests.

## Check

`dev/check.sh [stage]...` checks the stages named, or all of them, side by side, says what each said in order, and which
failed, and in a git checkout logs each to `dev/state/logs/<stage>.log`:

- `stamps`, every conflict marker a stamp's
- `pending`, what is left to stamp
- `format`, the Nix and the docs that hold no stamps pending, as `dev/write.sh` writes them
- `lint`, statix, deadnix and shellcheck
- `docs`, the references of the docs (`dev/refcheck.py`)
- `parts`, that `dev/parts.toml` holds what it declares (`dev/parts.py`)
- `index`, that `docs/index/` is as `python3 dev/index.py` writes it
- `eval`, `leaks` and `bats`, which build `.#stages.<stage>`
- `vm`, which builds `.#stages.vm` on the remote builder (`tools/bin/nix-remote.sh`).

All of them take ~60s, and ~240s when bats runs, as after a change to `tools/` or `dev/`. The flake's `stages.stamps`,
`stages.format` and `stages.lint` run the same stage in the sandbox (`tests/source.nix`). `dev/files.bash` gives
`dev/check.sh` and `dev/write.sh` the same files to read.

## Parts

`dev/parts.toml` declares the parts of o11n: each its stage, its layer, its doc, if it has one, and its code, which no
other part's code holds.

- `stages` names, in order, how far a part has come: felt, implied, mentioned, named, itemized, planned, drafted,
  solidified, cemented and protected.
- `layers` names the layers a part can be of: `domain`.

## Index

`docs/index/<part>.md` indexes a part's interface: for now the options of an org, each by its place in `org.toml`, its
type, its default and its description, under the part whose code declares it. The flake's `index` (`dev/index.nix`)
reads them from `org/context.nix`, evaluated for `tests/inventories/base`, which holds nothing: a default computed from
an entity's own config has a `defaultText`, as `lib.literalExpression` over the entity's options, the org's as
`org.<option>`, or as `lib.literalMD` where it draws on more, or the index fails to evaluate. `python3 dev/index.py`
writes a doc for each part that has any, and removes the rest, as `dev/write.sh` does. Each is a doc of the part it
indexes, and stamped like any other, so that a change to a part's interface is stamped.

## Write

`dev/write.sh [commit]` writes what follows from the code and the docs:

- the format of the Nix
- the index (`python3 dev/index.py`)
- the format of the docs that hold no stamps pending
- given a commit, each change to a doc since it as stamps pending, against what the operator had signed of it there.

A failing `format` stage says to run it rather than nixfmt or prettier: prettier reads a stamp's markers as Markdown and
reflows them.

## Stamps

A stamp is a git conflict in a doc, from `<<<<<<< signed` to `=======` as the operator last signed it and on to the
closing `>>>>>>>` as written now. `dev/stamps.sh` writes them, flags a conflict marker that isn't a stamp's, and the
stamps pending. The operator stamps them before work proceeds.

They're written against `refs/stamped/<branch>`, which `./dev/operator.sh stamp` sets: what the operator last stamped.
Until a branch has one, against the commit the turn started at, or else where the branch left main, so that what wasn't
stamped is stamped again rather than left out.

## Operator

In the dev shell, pulling and pushing through `as.sh` as `$O11N_DEV`:

```sh
./dev/operator.sh fetch [branch]    # switch to the branch, bring it and refs/stamped/* up to origin, say what is pending
./dev/operator.sh stamp [message]   # once nothing is pending: commit as "stamp", or the message, set refs/stamped/<branch>, push both, print the revision
./dev/operator.sh merge [branch]    # once nothing is pending and eval holds: squash onto main, push, delete the branch and its refs/stamped, print main's revision
./dev/operator.sh check-org         # with ORG set to an org's clone: build its eval stage with this tree as its o11n
```

`stamp` prints at once when nothing changed since it last stamped, as in `./dev/operator.sh stamp | osc copy`. Start the
next session at the revision it prints, with a first prompt that begins `At <revision>`.

## Agent

`./dev/agent.sh` runs as Claude Code's hooks (`.claude/settings.json`). Each says nothing unless the agent has something
to do, and exits 0 but `tool-end` and `turn-end`, which exit 2 to tell the agent.

- `session-start`, as a session starts: provisions a cloud container, then refuses work on what the commit the session
  starts at holds: stamps unsound or pending, and errors of format, lint, references or evaluation.
- `turn-start`, as a turn starts: moves a fresh session to the commit its first prompt starts at, or fast-forwards to
  what the operator pushed, and checks what that moved it to, refusing work on unsound stamps and telling of the rest.
- `tool-end`, after each Bash command: once the agent has commits no remote has, does what `turn-end` does, so that the
  turn ends with all pushed, as the environment's own Stop hook, which runs beside `turn-end`, expects.
- `turn-end`, as a turn ends: unless work was refused or the turn changed nothing, runs `dev/write.sh <commit>` against
  what the operator last stamped, commits what that changed as `turn-end` and pushes.

Run at request "hand over":

- `hand-over`: writes as `turn-end` does, commits all as `hand-over` and pushes, then checks the format, lint,
  references, evaluation, leaks and bats.

Outside the hooks, run `./dev/agent.sh` as they would: a prompt that starts `At <rev>` as `{"prompt": "At <rev>"}` on
turn-start's stdin, and source `dev/state/env` for the tools.

### Provisioning

In a cloud session, `session-start`:

- unshallows the clone
- fetches the `github:` and `gitlab:` inputs its `flake.lock` locks over git with `dev/fetch-inputs.sh`, as the forges'
  archives are refused or rate-limited there; nix then finds them in the store under the same content hash
- writes the dev shell's PATH to `dev/state/env`, for the hooks, and to `$CLAUDE_ENV_FILE`, for the session's commands
- roots the inputs and the dev shell in `dev/state/roots`, so that `nix store gc` keeps them
- with `O11N_REMOTE_BUILDER` set, says when the remote builder doesn't answer `nix-remote.sh info`.

## Lix daemon

`dev/lix-daemon.sh <dir>` starts Lix's daemon in the background as the remote builder runs it, on a store and socket of
its own in `<dir>` and for untrusted clients, and prints its store URL; stop it with `kill "$(cat <dir>/pid)"`. Left to
itself, Lix's daemon would listen on the socket the session's own nix takes for its daemon, and give fixed-output
fetches their network through pasta, which can't start in a cloud session.

## State

In `dev/state/`, out of git, which `rm -rf dev/state` resets:

- `env`: the dev shell's PATH, which session-start writes for the hooks and the session's commands.
- `roots`: the gc roots of the inputs and the dev shell.
- `session-start`: what session-start hands the session's first turn.
- `turn-start`: the commit the turn started at, as in `dev/write.sh "$(cat dev/state/turn-start)"`.
- `refused`: there while work is refused this turn.
- `logs/<stage>.log`: what `dev/check.sh` last said for the stage, under a line of when, at which commit and what ran
  it.

## Tests

`dev/test` holds the bats tests of `dev/`: `bats dev/test`, or `.#stages.bats` with those of `tools/`.
