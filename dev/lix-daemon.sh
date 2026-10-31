#!/usr/bin/env bash
# Usage: dev/lix-daemon.sh <dir>. Starts o11n's Lix daemon in the background as the remote builder
# runs it, on a store of its own in <dir>/root and for untrusted clients, prints its store URL,
# unix://<dir>/socket, and leaves its PID in <dir>/pid and its log in <dir>/log. NIX_CONFIG adds to
# its settings.
#
# Accommodating for the session: Lix's daemon listens on /nix/var/nix/daemon-socket/socket unless
# told otherwise, where the session's own nix, with store = auto, would take it for its daemon; and
# Lix gives fixed-output fetches their network through pasta, which can't start here.
set -euo pipefail

dir=${1:?usage: dev/lix-daemon.sh <dir>}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
[[ ! -S $dir/socket ]] || {
    echo "lix-daemon: $dir/socket is there already: kill \"\$(cat $dir/pid)\" first" >&2
    exit 1
}

lix=$(nix build --no-link --print-out-paths "$(git rev-parse --show-toplevel)#nixpkgs.legacyPackages.x86_64-linux.lix" | grep -v -- '-man$')

NIX_REMOTE="local?root=$dir/root" \
    NIX_DAEMON_SOCKET_PATH=$dir/socket \
    NIX_CONFIG="pasta-path =
extra-experimental-features = daemon-trust-override
${NIX_CONFIG:-}" \
    setsid "$lix/bin/nix-daemon" --force-untrusted >"$dir/log" 2>&1 </dev/null &
echo $! >"$dir/pid"

for _ in {1..100}; do
    if [[ -S $dir/socket ]]; then
        echo "unix://$dir/socket"
        exit 0
    fi
    kill -0 "$(cat "$dir/pid")" 2>/dev/null || break
    timeout 0.1 tail -f /dev/null || true
done
echo "lix-daemon: the daemon didn't start:" >&2
cat "$dir/log" >&2
exit 1
