#!/usr/bin/env bats
# tests/nix-remote.bats

# shellcheck disable=SC2016 # Accommodating for the stub, whose variables expand when it runs
setup() {
  nix_remote=$BATS_TEST_DIRNAME/../bin/nix-remote.sh
  o11n=0123456789abcdef0123456789abcdef01234567
  export O11N_REMOTE_BUILDER=https://builder.example O11N_REMOTE_BUILDER_TOKEN=token
  export GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@example.org
  export GIT_COMMITTER_NAME=alice GIT_COMMITTER_EMAIL=alice@example.org

  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!%s\n%s\n' "$BASH" '
    for arg; do
      [[ $arg != @* ]] || cat "${arg#@}" >>"$BATS_TEST_TMPDIR/headers"
    done
    echo "${*: -1}" >"$BATS_TEST_TMPDIR/url"
    cat "$BATS_TEST_TMPDIR/answer"
    exit "${CURL_STATUS:-0}"
  ' >"$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH

  cd "$BATS_TEST_TMPDIR" || exit
  git init -q --bare -b main origin.git
  git init -q -b main org
  cd org || exit
  git remote add origin ../origin.git
  git commit -q --allow-empty -m one
  git push -q -u origin main
}

@test "eval has the host build the stage at HEAD with o11n's revision, and exits as it did" {
  printf 'evaluating\nnix-remote-eval: exit 3\n' >"$BATS_TEST_TMPDIR/answer"

  run "$nix_remote" eval systems "$o11n"
  [ "$status" -eq 3 ]
  [[ $output == evaluating* ]]
  [[ $output != *"nix-remote-eval:"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/url")" = "https://builder.example/nix-eval/systems/$(git rev-parse HEAD)/$o11n" ]
  [ "$(cat "$BATS_TEST_TMPDIR/headers")" = "Authorization: Bearer token" ]

  printf 'nix-remote-eval: exit 0\n' >"$BATS_TEST_TMPDIR/answer"
  run "$nix_remote" eval eval
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/url")" = "https://builder.example/nix-eval/eval/$(git rev-parse HEAD)" ]
}

@test "eval says so when the host doesn't finish" {
  echo "another evaluation is running" >"$BATS_TEST_TMPDIR/answer"

  CURL_STATUS=22 run "$nix_remote" eval systems
  [ "$status" -eq 1 ]
  [[ $output == *"another evaluation is running"* ]]
  [[ $output == *"the evaluation on builder.example didn't finish"* ]]
}

@test "eval needs HEAD pushed and o11n's revision whole" {
  git commit -q --allow-empty -m two
  run "$nix_remote" eval systems
  [ "$status" -eq 1 ]
  [[ $output == *"$(git rev-parse HEAD) isn't pushed, and the host fetches it"* ]]

  git push -q
  run "$nix_remote" eval systems 0123abc
  [ "$status" -eq 1 ]
  [[ $output == *"0123abc: give o11n's revision whole"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/url" ]
}
