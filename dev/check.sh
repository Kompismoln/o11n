#!/usr/bin/env bash
# Usage: dev/check.sh [stage]..., from the clone's root in the dev shell. Each stage checks one thing
# and writes nothing git tracks; the stages named, or all of them, run side by side, and it fails,
# saying which did, if any does. It reads a directory without git as well, as nix's checks do.
set -euo pipefail
. dev/files.bash

STAGES=(stamps pending format lint docs parts index eval leaks bats vm)

stage-stamps() {
    dev/stamps.sh check
}

stage-pending() {
    dev/stamps.sh pending
}

# Accommodating for prettier, which says to fix its findings with --write: on a doc that holds
# stamps that reflows their markers, which write.sh leaves as they are.
stage-format() {
    local docs=()
    mapfile -d '' docs < <(unheld)
    files '*.nix' | xargs -0 nixfmt --check &&
        { ((${#docs[@]} == 0)) || prettier --check --log-level warn -- "${docs[@]}"; } && return
    echo "dev/write.sh writes the format; run it, not nixfmt or prettier." >&2
    return 1
}

stage-lint() {
    files '*.nix' | xargs -0 -n 1 statix check
    files '*.nix' | xargs -0 deadnix --fail
    files '*.sh' '*.bash' '*.bats' | { grep -zv '^tools/' || :; } | xargs -0 -r shellcheck -s bash
    # Accommodating for tools/.shellcheckrc, whose source path is relative to tools/.
    (cd tools && files '*.sh' '*.bash' '*.bats' 'test/bin/*' | xargs -0 shellcheck -s bash)
}

stage-docs() {
    python3 dev/refcheck.py
}

stage-parts() {
    python3 dev/parts.py
}

stage-index() {
    python3 dev/index.py --check || {
        echo "python3 dev/index.py writes it." >&2
        return 1
    }
}

stage-eval() {
    built eval
}

stage-leaks() {
    built leaks
}

stage-bats() {
    built bats
}

stage-vm() {
    tools/bin/nix-remote.sh build .#stages.vm
}

built() {
    nix build --no-link --quiet --no-warn-dirty ".#stages.$1"
}

fail() {
    echo "$1" >&2
    exit 1
}

# Optimization: stages named together run side by side, and what each says is said in order once
# all have run.
# Accommodating for bash, which ignores errexit wherever a status is tested: each stage runs as a
# process of its own, so that it still stops at its first failure.
lane() {
    local rc=0
    bash "${BASH_SOURCE[0]}" "$1" >"$said/$1.out" 2>"$said/$1.err" || rc=$?
    echo "$rc" >"$said/$1.rc"
}

stages=("$@")
((${#stages[@]} > 0)) || stages=("${STAGES[@]}")
for stage in "${stages[@]}"; do
    [[ " ${STAGES[*]} " == *" $stage "* ]] || fail "no stage $stage: ${STAGES[*]}"
done
if ((${#stages[@]} == 1)); then
    if git rev-parse --git-dir >/dev/null 2>&1; then
        log=dev/state/logs/${stages[0]}.log
        mkdir -p "$(dirname "$log")"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(git rev-parse --short HEAD) dev/check.sh ${stages[0]}" >"$log"
        teed=()
        exec > >(tee -a "$log")
        teed+=("$!")
        exec 2> >(tee -a "$log" >&2)
        teed+=("$!")
        trap 'rc=$?; exec >&- 2>&-; wait "${teed[@]}"; exit "$rc"' EXIT
    fi
    echo "• ${stages[0]}" >&2
    "stage-${stages[0]}"
    exit
fi
said=$(mktemp -d)
trap 'rm -rf "$said"' EXIT
for stage in "${stages[@]}"; do
    lane "$stage" &
done
wait
failed=()
for stage in "${stages[@]}"; do
    cat "$said/$stage.err" >&2
    cat "$said/$stage.out"
    [[ $(cat "$said/$stage.rc") -eq 0 ]] || failed+=("$stage")
done
((${#failed[@]} == 0)) || fail "• failed: ${failed[*]}"
