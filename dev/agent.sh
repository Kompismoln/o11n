#!/usr/bin/env bash
# Usage: ./dev/agent.sh session-start | turn-start | turn-end | hand-over [clone]. The hooks of
# .claude/settings.json run all but hand-over, with a hook's JSON on stdin. Given a clone, each sees
# to it alone, with the stages its dev/agent.bash names; without, to this clone and then to each
# clone beside it that pins o11n and has a dev/agent.bash. Each says nothing unless the agent has
# something to do, and exits 0, but turn-end, which exits 2 to have the turn go on.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command=${1:-}
case $command in
session-start | turn-start | turn-end | hand-over | provision) ;;
*)
    echo "usage: ./dev/agent.sh session-start | turn-start | turn-end | hand-over [clone]" >&2
    exit 1
    ;;
esac

event=""
case $command in
session-start | turn-start | turn-end) [[ -t 0 ]] || event="$(cat)" ;;
esac

# Prints this clone, then each beside it that pins o11n and has a dev/agent.bash: those come after,
# as they pin what this one pushes.
clones() {
    local root dir
    root=$(cd "$here/.." && pwd)
    echo "$root"
    for dir in "$root"/../*/; do
        dir=$(cd "$dir" && pwd)
        [[ $dir != "$root" && -f $dir/dev/agent.bash ]] || continue
        if jq -e '.nodes.o11n' "$dir/flake.lock" >/dev/null 2>&1; then echo "$dir"; fi
    done
}

# Runs the command for each clone, says what each said, under its name when there are several, and
# stops at a turn-end that has the turn go on. The clones after the first pin it, with O11N, unless
# it's set aside.
each() {
    local clones=() clone said rc
    mapfile -t clones < <(clones)
    if ((${#clones[@]} > 1)); then
        export AGENT_SEVERAL=yes
    fi
    for clone in "${clones[@]}"; do
        rc=0
        said=$(bash "$here/agent.sh" "$command" "$clone" 2>&1 <<<"$event") || rc=$?
        if [[ -n $said && -n ${AGENT_SEVERAL:-} ]]; then
            said="In $(basename "$clone"):"$'\n'"$said"
        fi
        if ((rc == 0)); then
            [[ -z $said ]] || printf '%s\n' "$said"
        else
            printf '%s\n' "$said" >&2
            exit "$rc"
        fi
        if [[ $clone == "${clones[0]}" && ! -e $clone/dev/aside ]]; then
            export O11N=$clone
        fi
    done
}

if [[ -z ${2:-} ]]; then
    each
    exit 0
fi

cd "$2"
# shellcheck source=/dev/null
. dev/agent.bash

ROOTS=dev/roots
STARTED=dev/session-start
TURN=dev/turn-start
REFUSED=dev/refused
ASIDE=dev/aside

remote() {
    [[ ${CLAUDE_CODE_REMOTE:-} == true ]]
}

# Accommodating for Claude Code, which hands what session-start writes to $CLAUDE_ENV_FILE to the
# session's commands but not to its hooks.
if [[ -f dev/env ]]; then
    # shellcheck source=/dev/null
    . ./dev/env
fi

field() {
    [[ -n $event ]] || return 0
    jq -r --arg name "$1" '.[$name] // "" | if type == "string" then . else tojson end' <<<"$event" 2>/dev/null || true
}

session-start() {
    local state=()
    case "$(field source)" in
    resume | clear | compact) ;;
    *)
        state+=(fresh)
        rm -f "$ASIDE"
        ;;
    esac
    if remote && ! provisioned; then
        state+=(unprovisioned refused)
    elif [[ ${state[*]} == fresh ]] && ! session-checked; then
        state+=(refused)
    fi
    echo "${state[*]}" >"$STARTED"
}

session-checked() {
    checked "${CHECKED_AT_SESSION_START[@]}"
    ((${#failed[@]})) || return 0
    refuse "$(named "${failed[@]}")" details
    sections
    return 1
}

# Accommodating for bash, which ignores errexit wherever a status is tested: provisioning runs as a
# process of its own, so that it still stops at its first failure.
provisioned() {
    if said="$(bash "$here/agent.sh" provision "$PWD" 2>&1)"; then
        # shellcheck source=/dev/null
        . ./dev/env
        return
    fi
    refuse "a container that fails to provision" details
    echo "$said"
    return 1
}

# Accommodating for a session's network, which refuses GitHub's archives: the github: inputs are
# fetched over git, and the dev shell's tools are rooted, so that nix store gc keeps them.
provision() {
    local inputs path i=0
    if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
        git fetch --quiet --unshallow
    fi
    rm -rf "$ROOTS"
    mkdir -p "$ROOTS"
    inputs="$("$here/fetch-github-inputs.sh")"
    for path in $inputs; do
        nix-store --quiet --add-root "$ROOTS/input-$((i++))" --realise "$path" >/dev/null
    done
    nix print-dev-env --quiet --no-warn-dirty --profile "$ROOTS/dev-shell" --json |
        jq -r '"export PATH=\(.variables.PATH.value | @sh):\"$PATH\""' >dev/env
    [[ -z ${CLAUDE_ENV_FILE:-} ]] || cat dev/env >>"$CLAUDE_ENV_FILE"
}

turn-start() {
    local state=() refused="" was revs rev
    if [[ -f $STARTED ]]; then
        read -ra state <"$STARTED"
        rm -f "$STARTED"
    fi
    [[ " ${state[*]} " != *" refused "* ]] || refused=refused
    was="$(git rev-parse HEAD)"
    if ! remote || [[ " ${state[*]} " == *" unprovisioned "* ]]; then
        :
    elif [[ " ${state[*]} " == *" fresh "* ]] && revs="$(supplied)"; then
        rm -f "$ASIDE"
        if ! rev="$(found "$revs")"; then
            if [[ -n ${AGENT_SEVERAL:-} ]]; then
                : >"$ASIDE"
                echo "Leave $(basename "$PWD") as it is this session: the prompt names no commit of it."
            else
                refuse "$revs, the commit the prompt starts at, which isn't to be found"
                refused=refused
            fi
        elif ! moved "$rev"; then
            refused=refused
        elif [[ $(git rev-parse HEAD) != "$was" ]]; then
            if provisioned && session-checked; then
                [[ -z $refused ]] ||
                    echo "Work isn't refused after all: $rev, the commit the prompt starts at, passes what session-start refused work for."
                refused=""
            else
                refused=refused
            fi
        fi
    elif [[ -z $refused && ! -e $ASIDE ]]; then
        synced
        if [[ $(git rev-parse HEAD) != "$was" ]]; then
            { provisioned && turn-checked; } || refused=refused
        fi
    fi
    git rev-parse HEAD >"$TURN"
    if [[ -n $refused ]]; then
        : >"$REFUSED"
    else
        rm -f "$REFUSED"
    fi
}

# Prints the revisions the prompt starts at, after "At", one for each clone the session sees to.
supplied() {
    local prompt words word revs=()
    prompt="$(field prompt)"
    read -ra words <<<"${prompt%%$'\n'*}"
    [[ ${words[0]:-} == At ]] || return 1
    for word in "${words[@]:1}"; do
        word=${word%[,.:;]}
        [[ $word =~ ^[0-9a-f]{7,40}$ ]] || break
        revs+=("$word")
    done
    ((${#revs[@]})) || return 1
    echo "${revs[*]}"
}

# Prints the first of the revisions that is a commit here.
found() {
    local rev
    git fetch --quiet origin 2>/dev/null || true
    for rev in $1; do
        if git rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
            echo "$rev"
            return
        fi
    done
    return 1
}

moved() {
    local sha branch
    sha="$(git rev-parse --verify --quiet "$1^{commit}")"
    [[ $sha != "$(git rev-parse HEAD)" ]] || return 0
    if branch="$(git symbolic-ref --quiet --short HEAD)"; then
        git checkout --quiet -B "$branch" "$sha"
    else
        git checkout --quiet --detach "$sha"
    fi
}

# Policy: the branch follows what the operator pushes to it, by fast-forward only and only with
# nothing of its own in the way, or else by the agent's merge; a fetch that fails is tried again at
# the next turn's start.
synced() {
    local branch upstream
    branch="$(git symbolic-ref --quiet --short HEAD)" || return 0
    upstream="origin/$branch"
    git fetch --quiet origin 2>/dev/null || return 0
    if ! git rev-parse --verify --quiet "$upstream" >/dev/null || git merge-base --is-ancestor "$upstream" HEAD; then
        return 0
    fi
    if git merge-base --is-ancestor HEAD "$upstream" && [[ -z $(git status --porcelain) ]]; then
        git merge --ff-only --quiet "$upstream"
    else
        echo "$upstream has commits $branch lacks, up to $(git log -1 --format='%h %s' "$upstream"):" \
            "commit what changed and merge $upstream before going on."
    fi
}

turn-checked() {
    local refusing=() telling=() stage
    checked "${REFUSED_AT_TURN_START[@]}" "${TOLD_AT_TURN_START[@]}"
    ((${#failed[@]})) || return 0
    for stage in "${failed[@]}"; do
        if [[ " ${REFUSED_AT_TURN_START[*]} " == *" $stage "* ]]; then
            refusing+=("$stage")
        else
            telling+=("$stage")
        fi
    done
    ((${#refusing[@]} == 0)) || refuse "$(named "${refusing[@]}")" details
    ((${#telling[@]} == 0)) || echo "Tell the user about $(named "${telling[@]}"), with what follows, and go on."
    sections
    ((${#refusing[@]} == 0))
}

refuse() {
    echo "Work is refused, for $1: tell the user so${2:+, with what follows,} and commit no changes this turn."
}

checked() {
    local line
    failed=()
    said="$(./check.sh "$@" 2>&1)" && return
    line="$(grep '^• failed: ' <<<"$said" | tail -n 1)" || true
    if [[ -n $line ]]; then
        read -ra failed <<<"${line#• failed: }"
    else
        failed=("$@")
    fi
}

sections() {
    awk -v kept=" ${failed[*]} " '/^• / { name = $0; sub(/^• /, "", name); on = index(kept, " " name " ") > 0 } on' <<<"$said"
}

named() {
    local stage names=()
    for stage in "$@"; do
        case $stage in
        stamps) names+=("conflict markers that aren't stamps") ;;
        pending) names+=("pending stamps") ;;
        format) names+=("formatting errors") ;;
        lint) names+=("lint errors") ;;
        docs) names+=("broken references") ;;
        eval) names+=("failing evaluation tests") ;;
        leaks) names+=("leaks") ;;
        bats) names+=("failing bats tests") ;;
        *) names+=("failing $stage") ;;
        esac
    done
    printf '%s, ' "${names[@]}" | sed 's/, $//'
}

# Policy: turn-end has the turn go on to set right what it found, but only once a turn, lest the
# turn never end. With O11N set, it writes even when the turn changed nothing here, as what it pins
# may have moved.
turn-end() {
    local start again="" before
    [[ $(field stop_hook_active) != true ]] || again=yes
    [[ ! -e $REFUSED && ! -e $ASIDE ]] || return 0
    start="$(cat "$TURN" 2>/dev/null)" ||
        ended "turn-end has no commit the turn started at to stamp against: run ./dev/agent.sh turn-start first."
    [[ $(git rev-parse HEAD) != "$start" || -n $(git status --porcelain) || -n ${O11N:-} ]] || return 0
    before="$(tree)"
    step ./write.sh "$start" ||
        ended "$stepped fails, as below: fix it before you end the turn, or tell the user why you can't." "$said"
    if [[ $(tree) != "$before" ]]; then
        { step git add --all && step git commit --quiet -m turn-end; } ||
            ended "$stepped fails, as below: see to it, and commit and push what turn-end wrote." "$said"
    fi
    step git push --quiet -u origin HEAD || ended "git push fails, as below: see to it, and push the branch." "$said"
}

ended() {
    [[ -z $again ]] || exit 0
    printf '%s\n' "$@" >&2
    exit 2
}

step() {
    stepped="$*"
    said="$("$@" 2>&1)"
}

tree() {
    local index
    index="$(mktemp)"
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE="$index" git add --all
    GIT_INDEX_FILE="$index" git write-tree
    rm -f "$index"
}

hand-over() {
    local start again="fix it and run ./dev/agent.sh hand-over again."
    if [[ -e $ASIDE ]]; then
        return
    elif [[ -e $REFUSED ]]; then
        echo "Work is refused this turn, so nothing is handed over: tell the user so."
        return
    elif ! start="$(cat "$TURN" 2>/dev/null)"; then
        echo "hand-over has no commit the turn started at to stamp against: run ./dev/agent.sh turn-start first."
        return
    fi
    if ! step ./write.sh "$start"; then
        printf '%s\n' "$stepped fails, as below: $again" "$said"
        return
    fi
    if ! { step git add --all && { git diff --cached --quiet || step git commit --quiet -m hand-over; }; } ||
        ! step git push --quiet -u origin HEAD; then
        printf '%s\n' "$stepped fails, as below: see to it, and commit and push the branch." "$said"
        return
    fi
    checked "${HANDED_OVER[@]}"
    if ((${#failed[@]})); then
        echo "Handed over with $(named "${failed[@]}"), as below: $again"
        sections
    fi
}

# Accommodating for Claude Code, which adds what a hook says to the session only if it exits 0, and
# what a Stop hook says only if it exits 2.
case $command in
session-start) session-start ;;
turn-start) turn-start ;;
turn-end) turn-end ;;
hand-over) hand-over ;;
provision) provision ;;
esac
exit 0
