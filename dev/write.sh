#!/usr/bin/env bash
# Usage: dev/write.sh [commit], from the clone's root in the dev shell. Writes what follows from the
# code and the docs: the format of the Nix and the Rust, the index, the format of the docs, and, given a commit,
# each change to a doc since it, the index's included, as stamps pending. It says what it wrote, and stops at the first that fails.
set -euo pipefail
. dev/files.bash

files '*.nix' | xargs -0 nixfmt
files '*.rs' | xargs -0 -r rustfmt
dev/index.sh
mapfile -d '' docs < <(unheld)
((${#docs[@]} == 0)) || prettier --write --log-level warn -- "${docs[@]}"
[[ -z ${1:-} ]] || dev/stamps.sh write "$1"
