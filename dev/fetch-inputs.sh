#!/usr/bin/env bash
# Usage: fetch-inputs.sh [flake.lock], this directory's unless given. Fetches each github: and
# gitlab: input it locks over git, at the locked revision, and prints its store path. That is
# the path nix's github: or gitlab: fetcher would make, so nix finds the input there instead of
# downloading the forge's archive, which a session's network refuses or rate-limits. An input it can't fetch, a
# private one say, it reports with nix's error and fails for, once it has tried the rest.
set -euo pipefail

refs=$(
    python3 - "${1:-flake.lock}" <<'EOF'
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
hosts = {"github": "github.com", "gitlab": "gitlab.com"}
locks = [node["locked"] for node in nodes if node.get("locked", {}).get("type") in hosts]
refs = {(lock.get("host", hosts[lock["type"]]), lock["owner"], lock["repo"], lock["rev"]) for lock in locks}
for ref in sorted(refs):
    print("git+https://{}/{}/{}?rev={}&shallow=1".format(*ref))
EOF
)

log=$(mktemp)
trap 'rm -f "$log"' EXIT

failed=0
for ref in $refs; do
    if json=$(nix flake prefetch --json "$ref" 2>"$log"); then
        python3 -c 'import json, sys; print(json.load(sys.stdin)["storePath"])' <<<"$json"
    else
        echo "fetch-inputs: could not fetch $ref:" >&2
        cat "$log" >&2
        failed=1
    fi
done
exit "$failed"
