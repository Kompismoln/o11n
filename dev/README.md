# Dev tools

## Check

`./check.sh [stage]...` checks the stages named, or all of them:

- `stamps`, every conflict marker a stamp's
- `pending`, what is left to stamp
- `format`, `lint`, `docs`, `eval`, `leaks`, `bats` and `vm`.

## Write

`./write.sh [commit]` writes what follows from the code and the docs:

- the format of the Nix and of the docs that hold no stamps pending
- given a commit, each change to a doc since it as stamps pending, against what the operator had signed of it there.

## State

In `dev/`, out of git:

- `env`: the dev shell's PATH, which session-start writes for the hooks and the session's commands.
- `session-start`: what session-start hands the session's first turn.
- `turn-start`: the commit the turn started at, as in `./write.sh "$(cat dev/turn-start)"`.
- `refused`: there while work is refused this turn.
- `stamped`: the commit `stamp` last found nothing pending in.

## Operator

In the dev shell, pulling and pushing through `as.sh` as `$O11N_DEV`, and as `operator` in an org's dev shell:

```sh
./dev/operator.sh fetch [branch]    # switch to the branch, bring it up to its tip on origin, say what is pending
./dev/operator.sh stamp [message]   # once nothing is pending: commit as "stamp", or the message, push, print the revision
./dev/operator.sh merge [branch]    # once nothing is pending and eval holds: squash onto main, push, print its revision
./dev/operator.sh check-org         # with ORG set to an org's clone: build its eval stage with this tree as its o11n
```

`stamp` prints at once when nothing changed since it last stamped, as in `./dev/operator.sh stamp | osc copy`. Start the
next session at the revision it prints, with a first prompt that begins `At <revision>`.

## Agent

All `./dev/agent.sh` exits 0 but `turn-end`, which exits 2 to have the turn go on, and says nothing unless the agent has
something to do.

Claude Code's hooks (`.claude/settings.json`):

- `./dev/agent.sh session-start`, as a session starts: provisions the cloud container, then refuses work on what the
  commit the session starts at holds: stamps unsound or pending, and errors of format, lint, references or evaluation.
- `./dev/agent.sh turn-start`, as a turn starts: moves a fresh session to the commit its first prompt starts at, or
  fast-forwards to what the operator pushed, and checks what that moved it to, refusing work on unsound stamps and
  telling of the rest.
- `./dev/agent.sh turn-end`, as a turn ends: unless work was refused, runs `./write.sh <commit>` against the commit the
  turn started at, commits what that changed as `turn-end` and pushes.

Run at request "hand over":

- `./dev/agent.sh hand-over`: writes as `turn-end` does, commits all as `hand-over` and pushes, then checks the format,
  lint, references, evaluation, leaks and bats.

Each sees to this clone with the stages `dev/agent.bash` names, and then to each clone beside it that pins o11n and has
a `dev/agent.bash` of its own, an org's, with the stages that one names: turn-end and hand-over write there with `O11N`
set to this clone, so that its `./write.sh` pins o11n to what this clone pushed. A fresh session's first prompt names a
commit of each clone it's to work on, as in `At <o11n revision> <org revision>`, and a clone it names none of is set
aside: left as it is for the session, and o11n then pinned by nothing.

A session with an org's clone beside this one starts in the directory above both, and reads no hooks of theirs. The
environment's setup script writes them there:

```sh
mkdir -p /home/user/.claude
cat >/home/user/.claude/settings.json <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/home/user/o11n/dev/agent.sh session-start", "timeout": 900 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/home/user/o11n/dev/agent.sh turn-start", "timeout": 900 }] }
    ],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/home/user/o11n/dev/agent.sh turn-end", "timeout": 300 }] }]
  }
}
JSON
```

`/status` in such a session names project settings among its setting sources when it reads them.
