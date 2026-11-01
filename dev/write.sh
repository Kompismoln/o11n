#!/usr/bin/env bash
# Usage: [STAMPED=<commit>] dev/write.sh [stage]..., from the clone's root in the dev shell. Writes what follows from
# the code and the docs for the stages named, or all of them, in order, says what it wrote, and stops at the first that
# fails. A stage of dev/check.sh checks what each writes: format, index and stamped.
set -euo pipefail

STAGES=(format index stamps)

write-format() {
    local docs=()
    o11n-dev files '*.nix' | xargs -0 -r nixfmt
    o11n-dev files '*.rs' | xargs -0 -r rustfmt
    mapfile -d '' docs < <(o11n-dev files --unheld)
    ((${#docs[@]} == 0)) || prettier --write --log-level warn -- "${docs[@]}"
}

write-index() {
    o11n-dev index write
}

# Policy: by default, stamps are written only against a STAMPED given, as the hooks give o11n-dev base.
write-stamps() {
    [[ -n ${STAMPED:-} ]] || {
        ((named)) || return 0
        echo "write.sh: stamps writes against STAMPED, which is unset" >&2
        return 1
    }
    o11n-dev stamps write "$STAMPED"
}

named=$#
stages=("$@")
((${#stages[@]} > 0)) || stages=("${STAGES[@]}")
for stage in "${stages[@]}"; do
    [[ " ${STAGES[*]} " == *" $stage "* ]] || {
        echo "no stage $stage: ${STAGES[*]}" >&2
        exit 1
    }
done
for stage in "${stages[@]}"; do
    "write-$stage"
done
