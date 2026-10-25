#!/usr/bin/env bash
# Usage: fetch.sh, on the branch an agent hands over on, as O11N_DEV. Pulls what it pushed and
# checks the baseline, which flags the stamps pending for a human to stamp.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[[ -n ${O11N_DEV:-} ]] || {
    echo "error: O11N_DEV is unset, so as.sh has no one to pull as" >&2
    exit 1
}

as.sh "$O11N_DEV" git pull --quiet --ff-only origin "$(git branch --show-current)"
nix build --no-link -L .#stages.baseline
