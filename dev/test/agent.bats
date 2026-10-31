#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  opening="<<<<<<< signed"
  cd "$BATS_TEST_TMPDIR" || exit
  unset CLAUDE_CODE_REMOTE CLAUDE_ENV_FILE CHECK_FAILS WRITE_FAILS O11N_REMOTE_BUILDER
  mkdir bin remote clones
  stub bin/nix 'echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log"
echo "{\"variables\":{\"PATH\":{\"value\":\"/dev-shell/bin\"}}}"'
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH

  project o11n
  cd clones/o11n || exit
  agent=$PWD/dev/agent.sh
}

stub() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$1"
  chmod +x "$1"
}

configure() {
  git config user.name "$1"
  git config user.email "$1@example.org"
  git config commit.gpgsign false
}

project() {
  git init -q --bare -b main "$BATS_TEST_TMPDIR/remote/$1.git"
  git init -q -b main "$BATS_TEST_TMPDIR/remote/$1-operator"
  (
    cd "$BATS_TEST_TMPDIR/remote/$1-operator" || exit
    configure operator
    git remote add origin "../$1.git"
    mkdir dev
    cp "$BATS_TEST_DIRNAME"/../{agent.sh,stamps.sh,.gitignore} dev/
    stub dev/check.sh 'echo "${PWD##*/}: $*" >>"$BATS_TEST_TMPDIR/checks.log"
echo "$PATH" >"$BATS_TEST_TMPDIR/checked-path"
failed=()
for stage in "$@"; do
  echo "• $stage" >&2
  if [[ " ${CHECK_FAILS:-} " == *" $stage "* ]]; then
    echo "$stage: broken"
    failed+=("$stage")
  fi
done
((${#failed[@]} == 0)) || { echo "• failed: ${failed[*]}" >&2; exit 1; }'
    stub dev/write.sh '[[ " ${WRITE_FAILS:-} " != *" ${PWD##*/} "* ]] || { echo "nixfmt: broken"; exit 1; }
[[ -z ${1:-} ]] || { echo "$1" >"$BATS_TEST_TMPDIR/against"; dev/stamps.sh write "$1" >/dev/null; }'
    stub dev/fetch-inputs.sh ':'
    echo one >file
    echo one >doc.md
    git add -A
    git commit -q -m one
    git push -q origin HEAD:main HEAD:work
  )
  git clone -q -b work "$BATS_TEST_TMPDIR/remote/$1.git" "$BATS_TEST_TMPDIR/clones/$1"
  (cd "$BATS_TEST_TMPDIR/clones/$1" && configure agent)
}

pushed() {
  cd "$BATS_TEST_TMPDIR/remote/o11n-operator" || exit
  echo "$1" >>file
  git commit -qam "$1"
  git push -q origin HEAD:work
  git rev-parse HEAD
}

commit() {
  echo "$1" >>"${2:-file}"
  git commit -qam "$1"
}

started() {
  mkdir -p dev/state
  echo "$1" >dev/state/session-start
}

@test "session-start checks a fresh session's commit, and says nothing when it holds" {
  run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat dev/state/session-start)" = fresh ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs parts index eval" ]
  [ -z "$(git status --porcelain)" ]
}

@test "session-start refuses work on what fails, with what it says" {
  CHECK_FAILS="pending eval" run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Work is refused, for pending stamps, failing evaluation tests: tell the user so, with what follows, and commit no changes this turn." ]
  [ "${lines[1]}" = "• pending" ]
  [ "${lines[2]}" = "pending: broken" ]
  [ "${lines[3]}" = "• eval" ]
  [ "${lines[4]}" = "eval: broken" ]
  [ "$(cat dev/state/session-start)" = "fresh refused" ]
}

@test "session-start provisions a cloud session from the dev shell, rooted in the clone" {
  CLAUDE_CODE_REMOTE=true CLAUDE_ENV_FILE=$BATS_TEST_TMPDIR/env run "$agent" session-start <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  grep -qxF "nix print-dev-env --quiet --no-warn-dirty --profile dev/state/roots/dev-shell --json" "$BATS_TEST_TMPDIR/nix.log"
  [ "$(cat dev/state/env)" = "export PATH='/dev-shell/bin':\"\$PATH\"" ]
  [ "$(cat "$BATS_TEST_TMPDIR/env")" = "$(cat dev/state/env)" ]
  [ -z "$(git status --porcelain)" ]
}

@test "session-start checks a fresh cloud session with the tools it provisioned" {
  CLAUDE_CODE_REMOTE=true run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ $(cat "$BATS_TEST_TMPDIR/checked-path") == /dev-shell/bin:* ]]
}

@test "session-start probes the remote builder in the cloud, and tells of it only when it doesn't answer" {
  mkdir -p tools/bin
  stub tools/bin/nix-remote.sh 'echo "nix-remote $*" >>"$BATS_TEST_TMPDIR/nix-remote.log"
[[ -z ${BUILDER_FAILS:-} ]] || { echo "error: no answer" >&2; exit 1; }'
  export O11N_REMOTE_BUILDER=builder.example

  CLAUDE_CODE_REMOTE=true run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat "$BATS_TEST_TMPDIR/nix-remote.log")" = "nix-remote info" ]

  BUILDER_FAILS=yes CLAUDE_CODE_REMOTE=true run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Tell the user that the remote builder, builder.example, doesn't answer, as below, so nothing can be built on it this session, and go on." ]
  [ "${lines[1]}" = "error: no answer" ]
  [ "$(cat dev/state/session-start)" = fresh ]

  rm "$BATS_TEST_TMPDIR/nix-remote.log"
  run "$agent" session-start <<<'{"source":"startup"}'
  unset O11N_REMOTE_BUILDER
  CLAUDE_CODE_REMOTE=true run "$agent" session-start <<<'{"source":"startup"}'
  [ ! -e "$BATS_TEST_TMPDIR/nix-remote.log" ]
}

@test "session-start checks nothing as a session resumes" {
  run "$agent" session-start <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$BATS_TEST_TMPDIR/checks.log" ]
}

@test "turn-start moves a fresh session to the commit its prompt starts at, and checks it" {
  rev=$(pushed two)
  started fresh

  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<"{\"prompt\":\"At ${rev:0:7}, on with it\"}"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git rev-parse HEAD)" = "$rev" ]
  [ "$(git branch --show-current)" = work ]
  [ "$(cat dev/state/turn-start)" = "$rev" ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs parts index eval" ]
  [ ! -e dev/state/session-start ]
  [ ! -e dev/state/refused ]
}

@test "turn-start lifts a refusal off a commit that holds, and refuses a commit that isn't there" {
  rev=$(pushed two)
  started "fresh refused"
  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<"{\"prompt\":\"At $rev\"}"
  [ "$output" = "Work isn't refused after all: $rev, the commit the prompt starts at, passes what session-start refused work for." ]
  [ ! -e dev/state/refused ]

  started fresh
  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<'{"prompt":"At 0123abc"}'
  [ "$status" -eq 0 ]
  [ "$output" = "Work is refused, for 0123abc, the commit the prompt starts at, which isn't to be found: tell the user so and commit no changes this turn." ]
  [ -e dev/state/refused ]
}

@test "turn-start fast-forwards to what the operator pushed, refuses on stamps and tells of the rest" {
  rev=$(pushed two)

  CHECK_FAILS="stamps lint" CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<'{"prompt":"go on"}'
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$rev" ]
  [ "${lines[0]}" = "Work is refused, for conflict markers that aren't stamps: tell the user so, with what follows, and commit no changes this turn." ]
  [ "${lines[1]}" = "Tell the user about lint errors, with what follows, and go on." ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs parts index eval" ]
  [ -e dev/state/refused ]
}

@test "turn-start says to merge what the operator pushed onto the branch's own, and leaves it outside the cloud" {
  rev=$(pushed two)
  commit mine doc.md
  was=$(git rev-parse HEAD)

  CLAUDE_CODE_REMOTE=true run "$agent" turn-start </dev/null
  [ "$output" = "origin/work has commits work lacks, up to ${rev:0:7} two: commit what changed and merge origin/work before going on." ]
  [ "$(git rev-parse HEAD)" = "$was" ]

  run "$agent" turn-start </dev/null
  [ "$output" = "" ]
  [ "$(cat dev/state/turn-start)" = "$was" ]
}

@test "tool-end does what turn-end does as soon as the agent commits, so the turn ends with all pushed" {
  "$agent" turn-start </dev/null
  echo two >>doc.md
  run "$agent" tool-end <<<'{"tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git log -1 --format=%s)" = one ]
  [ -n "$(git status --porcelain)" ]

  git commit -qam two
  run "$agent" tool-end <<<'{"tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git log -1 --format=%s)" = turn-end ]
  grep -qxF "$opening" doc.md
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]

  run "$agent" turn-end <<<'{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
  [ "$(git log -1 --format=%s)" = turn-end ]
  [ "$(git log -2 --format=%s | tail -1)" = two ]
}

@test "tool-end tells the agent when the push fails, and does nothing while work is refused" {
  "$agent" turn-start </dev/null
  commit two
  git remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  : >dev/state/refused
  run "$agent" tool-end </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  rm dev/state/refused
  run "$agent" tool-end </dev/null
  [ "$status" -eq 2 ]
  [[ ${lines[0]} == "git push fails, as below: see to it, and push the branch." ]]
}

@test "turn-end writes what the turn changed, stamped against its start, commits it as turn-end and pushes" {
  "$agent" turn-start </dev/null
  commit two doc.md

  run "$agent" turn-end <<<'{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git log -1 --format=%s)" = turn-end ]
  grep -qxF "$opening" doc.md
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]

  commit three
  run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = three ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
}

@test "turn-end holds the turn once on what fails, and not at all while work is refused" {
  "$agent" turn-start </dev/null
  commit two

  WRITE_FAILS=o11n run "$agent" turn-end <<<'{"stop_hook_active":false}'
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "dev/write.sh $(cat dev/state/turn-start) fails, as below: fix it before you end the turn, or tell the user why you can't." ]
  [ "${lines[1]}" = "nixfmt: broken" ]

  WRITE_FAILS=o11n run "$agent" turn-end <<<'{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  touch dev/state/refused
  WRITE_FAILS=o11n run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ "$(git rev-parse origin/work)" != "$(git rev-parse HEAD)" ]
}

@test "turn-end stamps against refs/stamped/<branch>, else the turn's start, else where the branch left main" {
  one=$(git rev-parse HEAD)
  commit two
  run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/against")" = "$one" ]

  "$agent" turn-start </dev/null
  turn=$(git rev-parse HEAD)
  commit three
  "$agent" turn-end </dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/against")" = "$turn" ]

  git update-ref refs/stamped/work "$one"
  commit four
  "$agent" turn-end </dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/against")" = "$one" ]
}

@test "turn-start fetches what the operator stamped, and turn-end says when there's nothing to stamp against" {
  rev=$(pushed two)
  git -C "$BATS_TEST_TMPDIR/remote/o11n-operator" push -q origin "$rev:refs/stamped/work"
  CLAUDE_CODE_REMOTE=true "$agent" turn-start </dev/null
  [ "$(git rev-parse refs/stamped/work)" = "$rev" ]

  git checkout -q --orphan alone
  rm dev/state/turn-start
  commit three
  run "$agent" turn-end </dev/null
  [ "$status" -eq 2 ]
  [ "$output" = "turn-end finds no commit to stamp against: no refs/stamped/<branch> HEAD is on, no dev/state/turn-start, and no main HEAD shares history with." ]
}

@test "hand-over writes, commits all as hand-over, pushes, and then checks" {
  "$agent" turn-start </dev/null
  echo two >>doc.md

  run "$agent" hand-over
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git log -1 --format=%s)" = hand-over ]
  grep -qxF "$opening" doc.md
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: format lint docs parts index eval leaks bats" ]
}

@test "hand-over says what fails once it has handed over, and hands nothing over while work is refused" {
  "$agent" turn-start </dev/null
  commit two

  CHECK_FAILS=bats run "$agent" hand-over
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Handed over with failing bats tests, as below: fix it and run ./dev/agent.sh hand-over again." ]
  [ "${lines[1]}" = "• bats" ]
  [ "${lines[2]}" = "bats: broken" ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]

  touch dev/state/refused
  commit three
  run "$agent" hand-over
  [ "$output" = "Work is refused this turn, so nothing is handed over: tell the user so." ]
  [ "$(git rev-parse origin/work)" != "$(git rev-parse HEAD)" ]
}

@test "agent.sh needs a command" {
  run "$agent"
  [ "$status" -eq 1 ]
  [[ $output == "usage: ./dev/agent.sh"* ]]
}
