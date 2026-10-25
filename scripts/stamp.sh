#!/usr/bin/env bash
# Usage: stamp.sh [message], as O11N_DEV, once the stamps pending are stamped. Checks the
# baseline the next session starts from, commits all that changed as the message, "stamp"
# unless given one, pushes, and prints the revision to start that session at.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[[ -n ${O11N_DEV:-} ]] || {
    echo "error: O11N_DEV is unset, so as.sh has no one to push as" >&2
    exit 1
}

# Accommodating for nix, which reads a dirty tree as git tracks it: a new file counts once added.
git add -A
nix build --no-link -L .#stages.baseline >&2
git diff --cached --quiet || git commit --quiet -m "${1:-stamp}"
as.sh "$O11N_DEV" git push --quiet -u origin HEAD
git rev-parse --short HEAD
