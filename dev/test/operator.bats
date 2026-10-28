#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  operator=$BATS_TEST_DIRNAME/../operator.sh
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir bin
  stub bin/as.sh 'shift; exec "$@"'
  stub bin/nix 'echo "$PWD: nix $*" >>"$BATS_TEST_TMPDIR/nix.log"; [[ $PWD != "${NIX_FAILS_IN:-}" ]]'
  stub bin/empty-editor ': >"$1"'
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH O11N_DEV=alice GIT_EDITOR=true
  export GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@example.org
  export GIT_COMMITTER_NAME=alice GIT_COMMITTER_EMAIL=alice@example.org
  unset CHECK_FAILS

  git init -q --bare -b main origin.git
  git init -q -b main repo
  cd repo || exit
  git config commit.gpgsign false
  top=$(git rev-parse --show-toplevel)
  git remote add origin ../origin.git
  mkdir dev
  cp "$BATS_TEST_DIRNAME/../.gitignore" dev/
  stub check.sh 'echo "$*" >>"$BATS_TEST_TMPDIR/checks.log"
for stage in "$@"; do
  if [[ " ${CHECK_FAILS:-} " == *" $stage "* ]]; then
    echo "flag: $stage" >&2
    exit 1
  fi
done'
  echo one >file
  git add -A
  git commit -q -m one
  git push -q -u origin main
  git checkout -q -b work
  git push -q -u origin work
}

stub() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$1"
  chmod +x "$1"
}

# Commits $1 on a line of its own to file, as the agent, and pushes it.
push() {
  local agent=$BATS_TEST_TMPDIR/agent
  [[ -d $agent ]] || git clone -q -c commit.gpgsign=false -b work "$BATS_TEST_TMPDIR/origin.git" "$agent"
  (
    cd "$agent" || exit
    export GIT_AUTHOR_NAME=agent GIT_AUTHOR_EMAIL=agent@example.org
    git pull -q && echo "$1" >>file && git commit -qam "$1" && git push -q
  )
}

commit() {
  echo "$1" >>file
  git commit -qam "$1"
}

pin() {
  printf '{"nodes":{"o11n":{"locked":{"type":"git","url":"file://%s","rev":"%s"}}}}\n' \
    "$BATS_TEST_TMPDIR/o11n" "$1" >flake.lock
  git add flake.lock
  git commit -qm "pin o11n"
}

@test "fetch switches to the branch, brings it up to its tip on origin, and says what is pending" {
  push two
  git checkout -q main

  CHECK_FAILS=pending run "$operator" fetch work
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = work ]
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/work)" ]
  [ "$output" = "flag: pending" ]
}

@test "fetch fails on a branch that went its own way" {
  commit mine
  push two

  run "$operator" fetch
  [ "$status" -ne 0 ]
  [ "$(tail -1 file)" = mine ]
}

@test "stamp, once nothing is pending, commits all as stamp, pushes and prints the revision" {
  push two
  "$operator" fetch
  echo two >>file
  echo new >new

  run "$operator" stamp
  [ "$status" -eq 0 ]
  [ "$output" = "$(git rev-parse --short HEAD)" ]
  [ "$(git log -1 --format=%s)" = stamp ]
  [ "$(git show HEAD:new)" = new ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
  [ "$(cat dev/stamped)" = "$(git rev-parse HEAD)" ]
}

@test "stamp commits nothing while something is pending, and takes a message" {
  echo two >>file

  CHECK_FAILS=pending run "$operator" stamp
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "error: pending, as flagged above; nothing was committed" ]
  [ "$(git log -1 --format=%s)" = one ]

  run "$operator" stamp "stamp the docs"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = "stamp the docs" ]
}

@test "stamp prints at once when nothing changed since it last stamped, and pushes what's committed" {
  "$operator" stamp
  rm "$BATS_TEST_TMPDIR/checks.log"

  run "$operator" stamp
  [ "$status" -eq 0 ]
  [ "$output" = "$(git rev-parse --short HEAD)" ]
  [ ! -e "$BATS_TEST_TMPDIR/checks.log" ]

  commit two
  run "$operator" stamp
  [ "$(git log -1 --format=%s)" = two ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
}

@test "merge squashes the branch onto main once it holds, pushes it and deletes the branch" {
  commit two
  commit three
  git push -q
  tree=$(git rev-parse "HEAD^{tree}")

  run "$operator" merge
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/checks.log")" = "pending eval" ]
  [ "${lines[-1]}" = "$(git rev-parse --short main)" ]
  [ "$(git branch --show-current)" = main ]
  [ "$(git rev-list --count main)" = 2 ]
  [ "$(git rev-parse "main^{tree}")" = "$tree" ]
  [ "$(git log -1 --format=%B main)" = "two

three" ]
  [ "$(git ls-remote ../origin.git refs/heads/main | cut -f1)" = "$(git rev-parse main)" ]
  run git rev-parse --verify -q refs/heads/work
  [ "$status" -ne 0 ]
  run git ls-remote --exit-code ../origin.git refs/heads/work
  [ "$status" -ne 0 ]
}

@test "merge commits what's left on the branch, and changes nothing on an empty message or when it doesn't hold" {
  commit two
  echo three >>file

  GIT_EDITOR=$BATS_TEST_TMPDIR/bin/empty-editor run "$operator" merge
  [ "$status" -eq 1 ]
  [[ $output == *"commit aborted; nothing was changed"* ]]
  [ "$(git log -1 --format=%s)" = merge ]
  [ "$(git branch --show-current)" = work ]
  [ "$(git rev-list --count main)" = 1 ]

  CHECK_FAILS="eval" run "$operator" merge
  [ "$status" -eq 1 ]
  [[ $output == *"'work' doesn't hold, for the above; nothing was merged"* ]]
  [ "$(git branch --show-current)" = work ]
  [ "$(git rev-list --count main)" = 1 ]
}

@test "merge refuses a branch that isn't on main's tip" {
  commit two
  git checkout -q main
  commit other
  git checkout -q work

  run "$operator" merge
  [ "$status" -eq 1 ]
  [[ $output == *"'work' is not based on the tip of 'main'"* ]]
}

@test "merge refuses a pin of o11n that isn't on o11n's main, and takes one that is" {
  git init -q -b main "$BATS_TEST_TMPDIR/o11n"
  git -C "$BATS_TEST_TMPDIR/o11n" commit -q --allow-empty -m one
  on_main=$(git -C "$BATS_TEST_TMPDIR/o11n" rev-parse HEAD)
  git -C "$BATS_TEST_TMPDIR/o11n" checkout -q -b branch
  git -C "$BATS_TEST_TMPDIR/o11n" commit -q --allow-empty -m two
  on_branch=$(git -C "$BATS_TEST_TMPDIR/o11n" rev-parse HEAD)
  git -C "$BATS_TEST_TMPDIR/o11n" checkout -q main

  pin "$on_branch"
  run "$operator" merge
  [ "$status" -eq 1 ]
  [[ $output == *"'work' pins o11n at $on_branch, which isn't on o11n's main"* ]]
  [ "$(git rev-list --count main)" = 1 ]

  pin "$on_main"
  run "$operator" merge
  [ "$status" -eq 0 ]
  [ "$(git show main:flake.lock | jq -r .nodes.o11n.locked.rev)" = "$on_main" ]
}

@test "check-org builds the org's eval stage with this tree as its o11n, ORG relative to the clone's root" {
  mkdir "$BATS_TEST_TMPDIR/org" sub
  cd sub || exit

  ORG=../org run "$operator" check-org
  [ "$status" -eq 0 ]
  grep -qxF "$BATS_TEST_TMPDIR/org: nix build --no-link -L .#stages.eval --override-input o11n git+file://$top" \
    "$BATS_TEST_TMPDIR/nix.log"

  ORG=$BATS_TEST_TMPDIR/org NIX_FAILS_IN=$BATS_TEST_TMPDIR/org run "$operator" check-org
  [ "$status" -ne 0 ]

  run "$operator" check-org
  [ "$status" -eq 1 ]
  [[ $output == *"ORG is unset"* ]]
}

@test "operator.sh needs O11N_DEV to pull and push as, and a command" {
  unset O11N_DEV
  for command in fetch stamp merge; do
    run "$operator" "$command"
    [ "$status" -eq 1 ]
    [[ $output == *"O11N_DEV is unset"* ]]
  done

  run "$operator"
  [ "$status" -eq 1 ]
  [[ $output == *"usage: ./dev/operator.sh"* ]]
}
