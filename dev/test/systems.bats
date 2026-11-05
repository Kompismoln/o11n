#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir bin org
  stub bin/nix 'echo "$PWD: nix $*" >>"$BATS_TEST_TMPDIR/nix.log"
[[ $PWD != "${NIX_FAILS_IN:-}" ]] || exit 1
if [[ $1 == eval ]]; then
  [[ -n ${SAME:-} ]] && rev=same || rev=$(grep -o "rev=[0-9a-f]*" <<<"$*")
  echo -n "/nix/store/$rev.drv"
fi'
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH ORG=$BATS_TEST_TMPDIR/org
  export GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@example.org
  export GIT_COMMITTER_NAME=alice GIT_COMMITTER_EMAIL=alice@example.org

  git init -q -b main repo
  cd repo || exit
  git config commit.gpgsign false
  top=$(git rev-parse --show-toplevel)
  echo one >file
  git add -A
  git commit -q -m one
  one=$(git rev-parse HEAD)
  echo two >file
  git commit -q -am two
  two=$(git rev-parse HEAD)
}

stub() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$1"
  chmod +x "$1"
}

@test "systems check builds the org's eval stage with this tree as its o11n, and the nix arguments" {
  run o11n-dev systems check -- --override-input secrets path:stub
  [ "$status" -eq 0 ]
  grep -qxF "$ORG: nix build --no-link -L .#stages.eval --override-input o11n git+file://$top --override-input secrets path:stub" \
    "$BATS_TEST_TMPDIR/nix.log"

  NIX_FAILS_IN=$ORG run o11n-dev systems check
  [ "$status" -ne 0 ]

  ORG='' run o11n-dev systems check
  [ "$status" -eq 1 ]
  [[ $output == *"ORG is unset"* ]]
}

@test "systems compare says of each host whether its system differs between two revisions, and fails if one does" {
  SAME=1 run o11n-dev systems compare HEAD~1 HEAD web gw
  [ "$status" -eq 0 ]
  [ "$output" = $'web same\ngw same' ]

  run o11n-dev systems compare HEAD~1 HEAD web -- --override-input secrets path:stub
  [ "$status" -eq 1 ]
  [ "$output" = "web differs: /nix/store/rev=$one.drv /nix/store/rev=$two.drv" ]
  grep -qF "$ORG: nix eval --raw --no-warn-dirty --override-input secrets path:stub --override-input o11n git+file://$top?rev=$one&shallow=1 .#nixosConfigurations.web --apply" \
    "$BATS_TEST_TMPDIR/nix.log"
  grep -qF "o11n.source.enable = false;" "$BATS_TEST_TMPDIR/nix.log"

  run o11n-dev systems compare nowhere HEAD web
  [ "$status" -eq 1 ]
  [[ $output == *"no revision nowhere"* ]]

  NIX_FAILS_IN=$ORG run o11n-dev systems compare HEAD~1 HEAD web
  [ "$status" -eq 1 ]
  [[ $output == *"web at $one doesn't evaluate"* ]]
}
