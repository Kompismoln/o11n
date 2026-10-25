#!/usr/bin/env bash
# Usage: check-org.sh, in an o11n clone, with ORG set to an org's clone, relative to this one's
# root or not. Builds the org's eval stage with this clone's tree as its o11n.
set -euo pipefail
here=$(git rev-parse --show-toplevel)
cd "$here"

[[ -n ${ORG:-} ]] || {
    echo "error: ORG is unset, so there's no org to check" >&2
    exit 1
}

cd "$ORG"
nix build --no-link -L .#stages.eval --override-input o11n "git+file://$here"
