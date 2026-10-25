#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  scripts=$BATS_TEST_DIRNAME/..
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir bin
  stub as.sh 'shift; exec "$@"'
  stub nix 'echo "$PWD: nix $*" >>"$BATS_TEST_TMPDIR/nix.log"; [[ $PWD != "${NIX_FAILS_IN:-}" ]]'
  stub empty-editor ': >"$1"'
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH O11N_DEV=alice GIT_EDITOR=true
  export GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@example.org
  export GIT_COMMITTER_NAME=alice GIT_COMMITTER_EMAIL=alice@example.org

  git init -q --bare -b main origin.git
  git init -q -b main repo
  cd repo || exit
  top=$(git rev-parse --show-toplevel)
  git remote add origin ../origin.git
  echo one >file
  git add file
  git commit -q -m one
  git push -q -u origin main
  git checkout -q -b work
  git push -q -u origin work
}

stub() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

handover() {
  local agent=$BATS_TEST_TMPDIR/agent
  [[ -d $agent ]] || git clone -q -b work "$BATS_TEST_TMPDIR/origin.git" "$agent"
  (cd "$agent" && git pull -q && echo "$1" >>file && git commit -qam "$1" && git push -q)
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

@test "fetch pulls what an agent handed over and checks the baseline" {
  handover two

  run "$scripts/fetch.sh"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/work)" ]
  [ "$(tail -1 file)" = two ]
  grep -qxF "$top: nix build --no-link -L .#stages.baseline" "$BATS_TEST_TMPDIR/nix.log"
}

@test "fetch fails with the baseline, and on a branch that went its own way" {
  handover two
  NIX_FAILS_IN=$top run "$scripts/fetch.sh"
  [ "$status" -ne 0 ]

  commit mine
  handover three
  run "$scripts/fetch.sh"
  [ "$status" -ne 0 ]
  [ "$(tail -1 file)" = mine ]
}

@test "stamp checks, commits all as stamp, pushes and prints the revision" {
  echo two >>file
  echo new >new

  run "$scripts/stamp.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git rev-parse --short HEAD)" ]
  [ "$(git log -1 --format=%s)" = stamp ]
  [ "$(git show HEAD:new)" = new ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
  grep -qxF "$top: nix build --no-link -L .#stages.baseline" "$BATS_TEST_TMPDIR/nix.log"
}

@test "stamp commits nothing the baseline fails, and pushes what's committed when nothing is left to" {
  echo two >>file
  NIX_FAILS_IN=$top run "$scripts/stamp.sh"
  [ "$status" -ne 0 ]
  [ "$(git log -1 --format=%s)" = one ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]

  git commit -qm two
  run "$scripts/stamp.sh"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = two ]
  [ "$(git rev-parse origin/work)" = "$(git rev-parse HEAD)" ]
}

@test "stamp takes a message" {
  echo two >>file

  run "$scripts/stamp.sh" "stamp the docs"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = "stamp the docs" ]
}

@test "merge squashes the branch onto main, pushes it and deletes the branch" {
  commit two
  commit three
  git push -q
  tree=$(git rev-parse "HEAD^{tree}")

  run "$scripts/merge.sh"
  [ "$status" -eq 0 ]
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

@test "merge changes nothing on an empty message, or when the baseline fails" {
  commit two

  GIT_EDITOR=$BATS_TEST_TMPDIR/bin/empty-editor run "$scripts/merge.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"commit aborted; nothing was changed"* ]]
  [ "$(git branch --show-current)" = work ]
  [ "$(git rev-list --count main)" = 1 ]

  NIX_FAILS_IN=$top run "$scripts/merge.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"'work' doesn't hold, for the above; nothing was changed"* ]]
  [ "$(git branch --show-current)" = work ]
  [ "$(git rev-list --count main)" = 1 ]
}

@test "merge refuses a branch that isn't on main's tip" {
  commit two
  git checkout -q main
  commit other
  git checkout -q work

  run "$scripts/merge.sh"
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
  run "$scripts/merge.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"'work' pins o11n at $on_branch, which isn't on o11n's main"* ]]
  [ "$(git rev-list --count main)" = 1 ]

  pin "$on_main"
  run "$scripts/merge.sh"
  [ "$status" -eq 0 ]
  [ "$(git show main:flake.lock | jq -r .nodes.o11n.locked.rev)" = "$on_main" ]
}

@test "check-org builds the org's eval stage with this tree as its o11n" {
  mkdir "$BATS_TEST_TMPDIR/org"

  ORG=$BATS_TEST_TMPDIR/org run "$scripts/check-org.sh"
  [ "$status" -eq 0 ]
  grep -qxF "$BATS_TEST_TMPDIR/org: nix build --no-link -L .#stages.eval --override-input o11n git+file://$top" \
    "$BATS_TEST_TMPDIR/nix.log"

  ORG=$BATS_TEST_TMPDIR/org NIX_FAILS_IN=$BATS_TEST_TMPDIR/org run "$scripts/check-org.sh"
  [ "$status" -ne 0 ]
}

@test "check-org takes ORG relative to the clone's root, and needs it" {
  mkdir "$BATS_TEST_TMPDIR/org" sub
  cd sub || exit

  ORG=../org run "$scripts/check-org.sh"
  [ "$status" -eq 0 ]
  grep -qF "$BATS_TEST_TMPDIR/org: nix build" "$BATS_TEST_TMPDIR/nix.log"

  run "$scripts/check-org.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"ORG is unset"* ]]
}

@test "the scripts need O11N_DEV to pull and push as" {
  unset O11N_DEV
  for script in fetch stamp merge; do
    run "$scripts/$script.sh"
    [ "$status" -eq 1 ]
    [[ $output == *"O11N_DEV is unset"* ]]
  done
}
