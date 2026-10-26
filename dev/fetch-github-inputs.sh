#!/usr/bin/env bash
# Usage: fetch-github-inputs.sh [flake.lock], this directory's unless given. Fetches each
# github: input it locks over git, at the locked revision, and prints its store path. That is
# the path nix's github: fetcher would make, so nix finds the input there instead of
# downloading GitHub's archive, which a session's network refuses. An input it can't fetch, a
# private one say, it reports with nix's error and fails for, once it has tried the rest.
set -euo pipefail

refs=$(
    python3 - "${1:-flake.lock}" <<'EOF'
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
locks = [node["locked"] for node in nodes if node.get("locked", {}).get("type") == "github"]
for lock in sorted({(lock["owner"], lock["repo"], lock["rev"]) for lock in locks}):
    print("git+https://github.com/{}/{}?rev={}&shallow=1".format(*lock))
EOF
)

log=$(mktemp)
trap 'rm -f "$log"' EXIT

failed=0
for ref in $refs; do
    if json=$(nix flake prefetch --json "$ref" 2>"$log"); then
        python3 -c 'import json, sys; print(json.load(sys.stdin)["storePath"])' <<<"$json"
    else
        echo "fetch-github-inputs: could not fetch $ref:" >&2
        cat "$log" >&2
        failed=1
    fi
done
exit "$failed"
