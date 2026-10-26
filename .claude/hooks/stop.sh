#!/bin/bash
# .claude/hooks/stop.sh
#
# At the end of a turn in a Claude Code cloud session, the stamps for what changed in the docs
# since a human last signed are to be written, so that work arrives stamped: stamps check, with
# the clone's own package. It blocks a turn's end once, with what to do; stamps pending are fine.

set -euo pipefail

[[ ${CLAUDE_CODE_REMOTE:-} == true ]] || exit 0
cd "$CLAUDE_PROJECT_DIR"

input=$(cat)
if python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("stop_hook_active") else 1)' "$input"; then
    exit 0
fi

if ! out=$(nix run .#stamps -- check 2>&1); then
    echo "$out" >&2
    echo "stop: write the stamps with nix run .#write-stamps, and commit what it writes" >&2
    exit 2
fi
