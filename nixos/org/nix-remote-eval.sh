#!/usr/bin/env bash
# nixos/org/nix-remote-eval.sh
#
# Runs once per connection, with the connection as stdin and stdout: an HTTP request from
# nginx, GET /nix-eval/<stage>/<org revision>[/<o11n revision>]. Builds that stage of the org
# at that revision, with its o11n input at the other one when given, and streams nix's output
# back, then the stage's output when it's a file: a report, built before or not. The last line is
# "nix-remote-eval: exit <status>". One runs at a time.
#
# ORG_FLAKE is the org's flake reference with {rev} where the revision goes; a line is written
# every HEARTBEAT seconds while nix runs. A git input is fetched with all its refs, for a
# revision on a branch.
set -euo pipefail

read -r method target _ || exit 0
while IFS= read -r header && [[ -n ${header%$'\r'} ]]; do :; done

respond() {
    printf 'HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n' "$1"
}

revision='[0-9a-f]{40}'
request="^/nix-eval/([a-z0-9][a-z0-9-]*)/($revision)(/($revision))?$"
if [[ $method != GET || ! $target =~ $request ]]; then
    respond "400 Bad Request"
    echo "usage: GET /nix-eval/<stage>/<org revision>[/<o11n revision>], with whole revisions"
    exit 0
fi
stage=${BASH_REMATCH[1]}
org=${ORG_FLAKE//\{rev\}/${BASH_REMATCH[2]}}
o11n_revision=${BASH_REMATCH[4]}

exec 9>"$CACHE_DIRECTORY/lock"
if ! flock -n 9; then
    respond "409 Conflict"
    echo "another evaluation is running"
    exit 0
fi

respond "200 OK"
exec 2>&1

# Policy: nginx closes a response that stays silent for 60s, as may the proxies past it, and
# evaluating is silent for minutes. The line also tells when the client is gone.
heartbeat() {
    local seconds=0
    while sleep "$HEARTBEAT"; do
        seconds=$((seconds + HEARTBEAT))
        echo "nix-remote-eval: running for ${seconds}s"
    done
}
heartbeat &
beat=$!
trap 'kill "$beat" 2>/dev/null || true' EXIT

nix=(nix --extra-experimental-features "nix-command flakes")

overrides=()
if [[ -n $o11n_revision ]]; then
    if ! o11n=$("${nix[@]}" flake metadata --json "$org" | jq -er --arg rev "$o11n_revision" '
        .locks.nodes[.locks.nodes[.locks.root].inputs.o11n // error("the org has no input named o11n")].original
        | if .type == "github" then "github:\(.owner)/\(.repo)/\($rev)"
          elif .type == "git" then "git+\(.url)?rev=\($rev)&allRefs=1"
          else error("the org takes o11n as a \(.type) input, which has no revisions") end'); then
        echo "nix-remote-eval: exit 1"
        exit 0
    fi
    overrides=(--override-input o11n "$o11n")
fi

outputs=$(mktemp)
"${nix[@]}" build --no-link --print-out-paths -L "$org#stages.$stage" "${overrides[@]}" >"$outputs" &
build=$!

status=0
wait -n -p first "$build" "$beat" || status=$?
if [[ $first == "$beat" ]]; then
    kill "$build"
    exit 0
fi
while IFS= read -r output; do
    if [[ -f $output ]]; then
        cat "$output"
    fi
done <"$outputs"
echo "nix-remote-eval: exit $status"
