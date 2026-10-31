#!/usr/bin/env bash
# Usage: fetch-inputs.sh [flake.lock], this directory's unless given. Fetches each github: and
# gitlab: input it locks over git, at the locked revision, and prints its store path. That is
# the path nix's github: or gitlab: fetcher would make, so nix finds the input there instead of
# downloading the forge's archive, which a session's network refuses or rate-limits. An input it can't fetch, a
# private one say, it reports with nix's error and fails for, once it has tried the rest.
set -euo pipefail

refs=$(
    jq -r '
        {github: "github.com", gitlab: "gitlab.com"} as $hosts
        | [.nodes[].locked // empty | select(.type // "" | in($hosts)) | [.host // $hosts[.type], .owner, .repo, .rev]]
        | unique[]
        | "git+https://\(.[0])/\(.[1])/\(.[2])?rev=\(.[3])&shallow=1"
    ' "${1:-flake.lock}"
)

log=$(mktemp)
trap 'rm -f "$log"' EXIT

failed=0
for ref in $refs; do
    if json=$(nix flake prefetch --json "$ref" 2>"$log"); then
        jq -r .storePath <<<"$json"
    else
        echo "fetch-inputs: could not fetch $ref:" >&2
        cat "$log" >&2
        failed=1
    fi
done
exit "$failed"
