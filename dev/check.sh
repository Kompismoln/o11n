#!/usr/bin/env bash
# Usage: dev/check.sh [stage]..., from the clone's root in the dev shell. Each stage checks one thing
# and writes nothing git tracks; the stages named, or all of them, run side by side, and it fails,
# saying which did, if any does. It reads a directory without git as well, as nix's checks do.
set -euo pipefail

STAGES=(stamps pending stamped format lint docs parts index eval leaks bats vm)

stage-stamps() {
    o11n-dev stamps check
}

stage-pending() {
    o11n-dev stamps pending
}

stage-stamped() {
    local against=${STAMPED:-}
    [[ -n $against ]] || against=$(o11n-dev base)
    o11n-dev stamps write --check "$against"
}

# Accommodating for prettier, which says to fix its findings with --write: on a doc that holds
# stamps that reflows their markers, which write.sh leaves as they are.
stage-format() {
    local docs=()
    mapfile -d '' docs < <(o11n-dev files --unheld)
    o11n-dev files '*.nix' | xargs -0 -r nixfmt --check &&
        o11n-dev files '*.rs' | xargs -0 -r rustfmt --check &&
        { ((${#docs[@]} == 0)) || prettier --check --log-level warn -- "${docs[@]}"; } && return
    echo "dev/write.sh writes the format; run it, not nixfmt, rustfmt or prettier." >&2
    return 1
}

stage-lint() {
    o11n-dev files '*.nix' | xargs -0 -r -n 1 statix check
    o11n-dev files '*.nix' | xargs -0 -r deadnix --fail
    o11n-dev files '*.sh' '*.bash' '*.bats' 'crates/o11n/test/bin/*' | xargs -0 -r shellcheck -s bash
}

stage-docs() {
    o11n-dev refs check
}

stage-parts() {
    o11n-dev parts check
}

stage-index() {
    o11n-dev index check || {
        echo "dev/write.sh writes it." >&2
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
    nix run --quiet --no-warn-dirty .#o11n -- remote build .#stages.vm
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
        commit=$(git rev-parse --short HEAD)
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $commit dev/check.sh ${stages[0]}" >"$log"
        teed=()
        exec > >(tee -a "$log")
        teed+=("$!")
        exec 2> >(tee -a "$log" >&2)
        teed+=("$!")
        trap 'rc=$?; exec >&- 2>&-; wait "${teed[@]}"
printf '"'"'{"stage":"%s","commit":"%s","status":%d}\n'"'"' "${stages[0]}" "$commit" "$rc" >"${log%.log}.json"
exit "$rc"' EXIT
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
