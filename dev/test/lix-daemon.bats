#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand when they run
setup() {
  cd "$BATS_TEST_TMPDIR" || exit
  git init -q
  mkdir -p bin lix/bin
  printf '#!%s\n%s\n' "$BASH" "echo $BATS_TEST_TMPDIR/lix-man; echo $BATS_TEST_TMPDIR/lix" >bin/nix
  printf '#!%s\n%s\n' "$BASH" '
    { echo "args: $*"; echo "remote: $NIX_REMOTE"; echo "socket: $NIX_DAEMON_SOCKET_PATH"; echo "$NIX_CONFIG"; } >"$BATS_TEST_TMPDIR/daemon.env"
    [[ -z ${DAEMON_FAILS:-} ]] || { echo "error: broken" >&2; exit 1; }
    python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$NIX_DAEMON_SOCKET_PATH"
    exec tail -f /dev/null
  ' >lix/bin/nix-daemon
  chmod +x bin/nix lix/bin/nix-daemon
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH
  lix=$BATS_TEST_DIRNAME/../lix-daemon.sh
}

teardown() {
  [[ ! -f test/pid ]] || kill "$(cat test/pid)" 2>/dev/null || true
}

@test "starts Lix's daemon on a store and socket of its own, untrusted and without pasta, and prints its URL" {
  NIX_CONFIG="sandbox = false" run "$lix" test
  [ "$status" -eq 0 ]
  [ "$output" = "unix://$BATS_TEST_TMPDIR/test/socket" ]
  [ "$(cat daemon.env)" = "args: --force-untrusted
remote: local?root=$BATS_TEST_TMPDIR/test/root
socket: $BATS_TEST_TMPDIR/test/socket
pasta-path =
extra-experimental-features = daemon-trust-override
sandbox = false" ]
  kill -0 "$(cat test/pid)"

  run "$lix" test
  [ "$status" -eq 1 ]
  [[ $output == *"socket is there already"* ]]
}

@test "says what the daemon said when it doesn't start" {
  DAEMON_FAILS=yes run "$lix" test
  [ "$status" -eq 1 ]
  [[ $output == *"the daemon didn't start:"*"error: broken"* ]]
}
