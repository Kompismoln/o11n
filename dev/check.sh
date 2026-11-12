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

# Policy: each VM test the builder ran is spooled as vmTests.<name>, with the time its driver says its script took, and
# a test that fails keeps none of the others from running.
stage-vm() {
    local drvs said rc=0
    said=$(evaluated vm)
    mapfile -t drvs <<<"$said"
    said=$(mktemp)
    timed "o11n remote build .#stages.vm" \
        nix run --quiet --no-warn-dirty .#o11n -- remote build --keep-going "${drvs[@]/%/^*}" 2>&1 |
        tee "$said" >&2 || rc=$?
    sed -nE 's/^vm-test-run-(o11n-)?([^>]+)> \(finished: run the VM test script, in ([0-9.]+) seconds\)$/\3 \2/p' "$said" |
        while read -r seconds name; do
            spool "$seconds" 0 "vmTests.$name"
        done
    rm -f "$said"
    return "$rc"
}

built() {
    local drvs said
    said=$(evaluated "$1")
    mapfile -t drvs <<<"$said"
    timed "nix build .#stages.$1" nix build --no-link --quiet --no-warn-dirty "${drvs[@]/%/^*}"
}

# Usage: evaluated <stage>: its jobs' derivations, a line each, as the evaluation of the stages named together, in
# EVALUATED, has them, or else as this evaluates them.
evaluated() {
    local dir=${EVALUATED:-}
    if [[ -z $dir ]]; then
        dir=$(mktemp -d)
        evaluate "$dir" "$1"
    fi
    until [[ -e $dir/$1 || -e $dir/$1.failed ]]; do
        sleep 0.2
    done
    if [[ -e $dir/$1.failed ]]; then
        cat "$dir/$1.failed" >&2
        return 1
    fi
    cat "$dir/$1"
    [[ -n ${EVALUATED:-} ]] || rm -rf "$dir"
}

# Usage: evaluate <dir> <stage>...: writes <dir>/<stage>, its jobs' derivations, as soon as nix-eval-jobs has evaluated
# them all, or <dir>/<stage>.failed, why it couldn't, for each of the stages, in their order.
# Accommodating for nix, whose evaluation of eval, leaks and vm in one process peaks at ~13 GB and of each at ~4, ~7 and
# ~6 GB, and of a job alone at up to ~4 GB: nix-eval-jobs evaluates their jobs in a worker per core and 2.5 GB of 3/4
# of what's available, which it keeps them within, restarting one that outgrows its share after its job, and running a
# job alone that outgrows them all.
# Optimization: a stage's jobs, at a tree of the clone's whose derivations are still in the store, are as they were
# when they were last evaluated there, in dev/state/evaluated/<stage>.
# Accommodating for the stages, which wait for what this writes: each stage that this leaves without either, as when
# something it runs fails, has a <dir>/<stage>.failed all the same.
# Accommodating for bash, which ignores errexit in what || tests: evaluation returns where it fails.
evaluate() {
    local dir=$1 stage
    (evaluation "$@") || true
    for stage in "${@:2}"; do
        [[ -e $dir/$stage || -e $dir/$stage.failed ]] ||
            echo "evaluate: $stage wasn't evaluated, as said above" >"$dir/$stage.failed"
    done
}

evaluation() {
    local dir=$1 tree stage line path drv error order=() budget workers cap counts began select rc=0
    local -A left
    shift
    tree=$(worktree) || tree=""
    for stage in "$@"; do
        if [[ -n $tree && $(head -n 1 "dev/state/evaluated/$stage" 2>/dev/null) == "$tree" ]] &&
            tail -n +2 "dev/state/evaluated/$stage" | xargs -r nix-store --check-validity 2>/dev/null; then
            tail -n +2 "dev/state/evaluated/$stage" >"$dir/$stage"
        else
            order+=("$stage")
        fi
    done
    ((${#order[@]} > 0)) || return 0
    began=$EPOCHREALTIME
    counts=$(nix eval --json --quiet --no-warn-dirty .#jobs \
        --apply 'jobs: builtins.mapAttrs (_: stage: builtins.length (builtins.attrNames stage)) jobs') || return
    for stage in "${order[@]}"; do
        left[$stage]=$(jq -er --arg stage "$stage" '.[$stage]' <<<"$counts") || return
        : >"$dir/$stage.part"
    done
    budget=$(($(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo) * 3 / 4))
    ((budget >= 4096)) || budget=4096
    workers=$(nproc)
    ((workers <= budget / 2560)) || workers=$((budget / 2560))
    ((workers >= 1)) || workers=1
    cap=$((budget / workers))
    # Policy: a job's name is <i>/<stage>/<name>, <i> its stage's place in the order, as nix-eval-jobs takes the jobs
    # in the order of their names.
    select="jobs: let order = [ $(printf '"%s" ' "${order[@]}")]; in builtins.listToAttrs (builtins.concatLists
        (builtins.genList (i: let stage = builtins.elemAt order i; in map (name: {
          name = \"\${toString i}/\${stage}/\${name}\"; value = jobs.\${stage}.\${name};
        }) (builtins.attrNames jobs.\${stage})) (builtins.length order)))"
    while read -r line; do
        path=$(jq -r '.attrPath[0]' <<<"$line")
        stage=${path#*/}
        stage=${stage%%/*}
        drv=$(jq -r '.drvPath // ""' <<<"$line")
        error=$(jq -r '.error // ""' <<<"$line")
        if [[ -n $error ]]; then
            printf '%s: %s\n' "${path#*/}" "$error" >>"$dir/$stage.errors"
        else
            echo "$drv" >>"$dir/$stage.part"
        fi
        left[$stage]=$((left[$stage] - 1))
        ((left[$stage] == 0)) || continue
        if [[ -e $dir/$stage.errors ]]; then
            mv "$dir/$stage.errors" "$dir/$stage.failed"
        else
            [[ -z $tree ]] || { echo "$tree" && cat "$dir/$stage.part"; } >"dev/state/evaluated/$stage.new"
            [[ -z $tree ]] || mv "dev/state/evaluated/$stage.new" "dev/state/evaluated/$stage"
            mv "$dir/$stage.part" "$dir/$stage"
        fi
    done < <(nix-eval-jobs --flake .#legacyPackages.x86_64-linux.jobs --select "$select" \
        --workers "$workers" --max-memory-size "$cap" --option eval-cache false)
    for stage in "${order[@]}"; do
        [[ -e $dir/$stage ]] || rc=1
    done
    spooled "$began" "$rc" "nix-eval-jobs ${order[*]}"
}

# Fact: nix reads the flake as the tree of the clone's tracked files as they are now, which git stash create commits.
worktree() {
    local stash
    stash=$(git stash create 2>/dev/null) || return 1
    mkdir -p dev/state/evaluated
    git rev-parse "${stash:-HEAD}^{tree}"
}

# Duplication: crates/o11n-dev/src/costs.rs:Cost reads these columns, in this order; o11n-dev folds the spool only in a
# checkout, as told by dev/costs.tsv being there.
spool() {
    [[ -n ${MACHINE_CLASS:-} && -f dev/costs.tsv ]] || return 0
    mkdir -p dev/state
    printf '%s\t%s\t%.1f\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MACHINE_CLASS" "$1" "$2" \
        "${O11N_BESIDE:-0}" "$(git rev-parse --short HEAD 2>/dev/null)" "$3" >>dev/state/costs-spool.tsv
}

spooled() {
    spool "$(awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }')" "$2" "$3"
}

timed() {
    local began=$EPOCHREALTIME rc=0
    "${@:2}" || rc=$?
    spooled "$began" "$rc" "$1"
    return "$rc"
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
        began=$EPOCHREALTIME
        trap 'rc=$?; spooled "$began" "$rc" "dev/check.sh ${stages[0]}"; exec >&- 2>&-; wait "${teed[@]}"
printf '"'"'{"stage":"%s","commit":"%s","status":%d}\n'"'"' "${stages[0]}" "$commit" "$rc" >"${log%.log}.json"
exit "$rc"' EXIT
    fi
    echo "• ${stages[0]}" >&2
    "stage-${stages[0]}"
    exit
fi
began=$EPOCHREALTIME
said=$(mktemp -d)
trap 'rm -rf "$said"' EXIT
export EVALUATED=$said/evaluated O11N_BESIDE=$((${#stages[@]} - 1))
mkdir "$EVALUATED"
# Optimization: the stages named that build jobs are evaluated together, vm's first, as its VMs take longest, and
# then bats', whose one job evaluates in a second.
heavy=()
for stage in vm bats eval leaks; do
    [[ " ${stages[*]} " != *" $stage "* ]] || heavy+=("$stage")
done
((${#heavy[@]} == 0)) || evaluate "$EVALUATED" "${heavy[@]}" 2>"$said/evaluate.err" &
for stage in "${stages[@]}"; do
    lane "$stage" &
done
wait
failed=()
[[ ! -e $said/evaluate.err ]] || cat "$said/evaluate.err" >&2
for stage in "${stages[@]}"; do
    cat "$said/$stage.err" >&2
    cat "$said/$stage.out"
    [[ $(cat "$said/$stage.rc") -eq 0 ]] || failed+=("$stage")
done
O11N_BESIDE=0 spooled "$began" "$((${#failed[@]} > 0))" "dev/check.sh${*:+ $*}"
((${#failed[@]} == 0)) || fail "• failed: ${failed[*]}"
