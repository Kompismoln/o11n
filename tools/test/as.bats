#!/usr/bin/env bats
# tests/as.bats

setup() {
  load helpers.sh
  setup-testenv
}

@test "as leaves an agent it didn't start alone" {
  eval "$(ssh-agent -s)" >/dev/null
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere"

  run as.sh testadmin true
  [ "$status" -ne 0 ]
  [[ $output != *"SSH_AGENT_PID"* ]]
  kill -0 "$SSH_AGENT_PID"
  ssh-agent -k >/dev/null
}
