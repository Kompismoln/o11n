#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  opening="<<<<<<< signed"
  cd "$BATS_TEST_TMPDIR" || exit
  unset CLAUDE_CODE_REMOTE CLAUDE_ENV_FILE CHECK_FAILS WRITE_FAILS O11N AGENT_SEVERAL
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

# Makes clones/$1, the agent's clone of what remote/$1-operator pushes to remote/$1.git, its work
# branch, with dev/agent.sh and stubs of check.sh and write.sh, and, given a flake.lock, that too.
project() {
  git init -q --bare -b main "$BATS_TEST_TMPDIR/remote/$1.git"
  git init -q -b main "$BATS_TEST_TMPDIR/remote/$1-operator"
  (
    cd "$BATS_TEST_TMPDIR/remote/$1-operator" || exit
    configure operator
    git remote add origin "../$1.git"
    mkdir dev
    cp "$BATS_TEST_DIRNAME"/../{agent.sh,agent.bash,stamps.sh,.gitignore} dev/
    stub check.sh 'echo "${PWD##*/}: $*" >>"$BATS_TEST_TMPDIR/checks.log"
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
    stub write.sh '[[ " ${WRITE_FAILS:-} " != *" ${PWD##*/} "* ]] || { echo "nixfmt: broken"; exit 1; }
[[ -z ${O11N:-} ]] || git -C "$O11N" rev-parse HEAD >pin
[[ -z ${1:-} ]] || dev/stamps.sh write "$1" >/dev/null'
    stub dev/fetch-github-inputs.sh ':'
    if [[ -n ${2:-} ]]; then
      echo "$2" >flake.lock
    fi
    echo one >file
    echo one >doc.md
    git add -A
    git commit -q -m one
    git push -q origin HEAD:main HEAD:work
  )
  git clone -q -b work "$BATS_TEST_TMPDIR/remote/$1.git" "$BATS_TEST_TMPDIR/clones/$1"
  (cd "$BATS_TEST_TMPDIR/clones/$1" && configure agent)
}

org() {
  project org '{"nodes":{"o11n":{"locked":{"type":"github","rev":"0000000"}}}}'
}

# Commits $1 on a line of its own to file as the operator of ${2:-o11n}, pushes it to work, and
# prints its revision.
pushed() {
  cd "$BATS_TEST_TMPDIR/remote/${2:-o11n}-operator" || exit
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
  echo "$1" >"${2:-.}/dev/session-start"
}

@test "session-start checks a fresh session's commit, and says nothing when it holds" {
  run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat dev/session-start)" = fresh ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs eval" ]
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
  [ "$(cat dev/session-start)" = "fresh refused" ]
}

@test "session-start provisions a cloud session from the dev shell, rooted in the clone" {
  CLAUDE_CODE_REMOTE=true CLAUDE_ENV_FILE=$BATS_TEST_TMPDIR/env run "$agent" session-start <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  grep -qxF "nix print-dev-env --quiet --no-warn-dirty --profile dev/roots/dev-shell --json" "$BATS_TEST_TMPDIR/nix.log"
  [ "$(cat dev/env)" = "export PATH='/dev-shell/bin':\"\$PATH\"" ]
  [ "$(cat "$BATS_TEST_TMPDIR/env")" = "$(cat dev/env)" ]
  [ -z "$(git status --porcelain)" ]
}

@test "session-start checks a fresh cloud session with the tools it provisioned" {
  CLAUDE_CODE_REMOTE=true run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ $(cat "$BATS_TEST_TMPDIR/checked-path") == /dev-shell/bin:* ]]
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
  [ "$(cat dev/turn-start)" = "$rev" ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs eval" ]
  [ ! -e dev/session-start ]
  [ ! -e dev/refused ]
}

@test "turn-start lifts a refusal off a commit that holds, and refuses a commit that isn't there" {
  rev=$(pushed two)
  started "fresh refused"
  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<"{\"prompt\":\"At $rev\"}"
  [ "$output" = "Work isn't refused after all: $rev, the commit the prompt starts at, passes what session-start refused work for." ]
  [ ! -e dev/refused ]

  started fresh
  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<'{"prompt":"At 0123abc"}'
  [ "$status" -eq 0 ]
  [ "$output" = "Work is refused, for 0123abc, the commit the prompt starts at, which isn't to be found: tell the user so and commit no changes this turn." ]
  [ -e dev/refused ]
}

@test "turn-start fast-forwards to what the operator pushed, refuses on stamps and tells of the rest" {
  rev=$(pushed two)

  CHECK_FAILS="stamps lint" CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<'{"prompt":"go on"}'
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$rev" ]
  [ "${lines[0]}" = "Work is refused, for conflict markers that aren't stamps: tell the user so, with what follows, and commit no changes this turn." ]
  [ "${lines[1]}" = "Tell the user about lint errors, with what follows, and go on." ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs eval" ]
  [ -e dev/refused ]
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
  [ "$(cat dev/turn-start)" = "$was" ]
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
  [ "${lines[0]}" = "./write.sh $(cat dev/turn-start) fails, as below: fix it before you end the turn, or tell the user why you can't." ]
  [ "${lines[1]}" = "nixfmt: broken" ]

  WRITE_FAILS=o11n run "$agent" turn-end <<<'{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  touch dev/refused
  WRITE_FAILS=o11n run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ "$(git rev-parse origin/work)" != "$(git rev-parse HEAD)" ]
}

@test "turn-end needs the commit the turn started at" {
  commit two
  run "$agent" turn-end </dev/null
  [ "$status" -eq 2 ]
  [ "$output" = "turn-end has no commit the turn started at to stamp against: run ./dev/agent.sh turn-start first." ]
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
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: format lint docs eval leaks bats" ]
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

  touch dev/refused
  commit three
  run "$agent" hand-over
  [ "$output" = "Work is refused this turn, so nothing is handed over: tell the user so." ]
  [ "$(git rev-parse origin/work)" != "$(git rev-parse HEAD)" ]
}

@test "with a clone beside it that pins o11n, each command sees to o11n and then to it, under their names" {
  org

  CHECK_FAILS=pending run "$agent" session-start <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "In o11n:" ]
  [ "${lines[1]}" = "Work is refused, for pending stamps: tell the user so, with what follows, and commit no changes this turn." ]
  [ "${lines[4]}" = "In org:" ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "o11n: stamps pending format lint docs eval
org: stamps pending format lint docs eval" ]
  [ -e ../org/dev/session-start ]
}

@test "turn-start moves each clone to its revision in the prompt, and sets aside one the prompt names none of" {
  org
  rev=$(pushed two)
  orgrev=$(pushed two org)
  started fresh
  started fresh ../org

  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<"{\"prompt\":\"At ${rev:0:7} ${orgrev:0:7}\"}"
  [ "$output" = "" ]
  [ "$(git rev-parse HEAD)" = "$rev" ]
  [ "$(git -C ../org rev-parse HEAD)" = "$orgrev" ]

  started fresh
  started fresh ../org
  CLAUDE_CODE_REMOTE=true run "$agent" turn-start <<<"{\"prompt\":\"At $rev\"}"
  [ "$output" = "In org:
Leave org as it is this session: the prompt names no commit of it." ]
  [ -e ../org/dev/aside ]
  [ ! -e dev/aside ]
}

@test "turn-end pins the clone beside o11n to what o11n just pushed, even when the turn changed nothing there" {
  org
  "$agent" turn-start </dev/null
  commit two

  run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
  [ "$(git -C ../org show origin/work:pin)" = "$(git rev-parse HEAD)" ]
  [ "$(git -C ../org log -1 --format=%s)" = turn-end ]
}

@test "turn-end that holds the turn in o11n doesn't reach the clone beside it" {
  org
  "$agent" turn-start </dev/null
  commit two

  WRITE_FAILS=o11n run "$agent" turn-end </dev/null
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "In o11n:" ]
  [ "${lines[1]}" = "./write.sh $(cat dev/turn-start) fails, as below: fix it before you end the turn, or tell the user why you can't." ]
  [ ! -e ../org/pin ]
}

@test "a clone set aside is left as it is, and nothing pins o11n while o11n is set aside" {
  org
  "$agent" turn-start </dev/null
  commit two
  touch ../org/dev/aside
  run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ ! -e ../org/pin ]
  [ "$(git -C ../org log -1 --format=%s)" = one ]

  rm ../org/dev/aside
  touch dev/aside
  (cd ../org && commit three)
  run "$agent" turn-end </dev/null
  [ "$status" -eq 0 ]
  [ ! -e ../org/pin ]
  [ "$(git -C ../org rev-parse origin/work)" = "$(git -C ../org rev-parse HEAD)" ]
}

@test "agent.sh needs a command" {
  run "$agent"
  [ "$status" -eq 1 ]
  [[ $output == "usage: ./dev/agent.sh"* ]]
}
