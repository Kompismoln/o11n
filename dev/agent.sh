#!/usr/bin/env bash
# Usage: ./dev/agent.sh session-start | turn-start | tool-end | turn-end | hand-over. The hooks of
# .claude/settings.json run all but hand-over, with a hook's JSON on stdin. Each says nothing unless
# the agent has something to do, and exits 0, but tool-end and turn-end, which exit 2 to tell the
# agent.
set -euo pipefail

command=${1:-}
case $command in
session-start | turn-start | tool-end | turn-end | hand-over | provision) ;;
*)
    echo "usage: ./dev/agent.sh session-start | turn-start | tool-end | turn-end | hand-over" >&2
    exit 1
    ;;
esac

event=""
case $command in
session-start | turn-start | tool-end | turn-end) [[ -t 0 ]] || event="$(cat)" ;;
esac

cd "$(git rev-parse --show-toplevel)"

CHECKED_AT_SESSION_START=(stamps pending format lint docs parts index eval)
REFUSED_AT_TURN_START=(stamps)
TOLD_AT_TURN_START=(pending format lint docs parts index eval)
HANDED_OVER=(format lint docs parts index eval leaks bats)

STATE=dev/state
ENV=$STATE/env
ROOTS=$STATE/roots
STARTED=$STATE/session-start
TURN=$STATE/turn-start
REFUSED=$STATE/refused
mkdir -p "$STATE"

remote() {
    [[ ${CLAUDE_CODE_REMOTE:-} == true ]]
}

# Accommodating for Claude Code, which hands what session-start writes to $CLAUDE_ENV_FILE to the
# session's commands but not to its hooks.
if [[ -f $ENV ]]; then
    # shellcheck source=/dev/null
    . "$ENV"
fi

field() {
    [[ -n $event ]] || return 0
    jq -r --arg name "$1" '.[$name] // "" | if type == "string" then . else tojson end' <<<"$event" 2>/dev/null || true
}

session-start() {
    local state=()
    case "$(field source)" in
    resume | clear | compact) ;;
    *) state+=(fresh) ;;
    esac
    if remote && ! provisioned; then
        state+=(unprovisioned refused)
    else
        builder-probed
        if [[ ${state[*]} == fresh ]] && ! session-checked; then
            state+=(refused)
        fi
    fi
    echo "${state[*]}" >"$STARTED"
}

# Policy: a builder that doesn't answer is told of, not refused for, as only VM tests and remote
# evaluation need it.
builder-probed() {
    remote && [[ -n ${O11N_REMOTE_BUILDER:-} && -x tools/bin/nix-remote.sh ]] || return 0
    said="$(timeout 120 tools/bin/nix-remote.sh info 2>&1)" && return
    echo "Tell the user that the remote builder, $O11N_REMOTE_BUILDER, doesn't answer, as below, so nothing can be built on it this session, and go on."
    echo "$said"
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
    if said="$(bash "${BASH_SOURCE[0]}" provision 2>&1)"; then
        # shellcheck source=/dev/null
        . "$ENV"
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
    inputs="$(dev/fetch-inputs.sh)"
    for path in $inputs; do
        nix-store --quiet --add-root "$ROOTS/input-$((i++))" --realise "$path" >/dev/null
    done
    nix print-dev-env --quiet --no-warn-dirty --profile "$ROOTS/dev-shell" --json |
        jq -r '"export PATH=\(.variables.PATH.value | @sh):\"$PATH\""' >"$ENV"
    [[ -z ${CLAUDE_ENV_FILE:-} ]] || cat "$ENV" >>"$CLAUDE_ENV_FILE"
}

turn-start() {
    local state=() refused="" was rev
    if [[ -f $STARTED ]]; then
        read -ra state <"$STARTED"
        rm -f "$STARTED"
    fi
    [[ " ${state[*]} " != *" refused "* ]] || refused=refused
    was="$(git rev-parse HEAD)"
    if ! remote || [[ " ${state[*]} " == *" unprovisioned "* ]]; then
        :
    elif [[ " ${state[*]} " == *" fresh "* ]] && rev="$(supplied)"; then
        if ! found "$rev"; then
            refuse "$rev, the commit the prompt starts at, which isn't to be found"
            refused=refused
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
    elif [[ -z $refused ]]; then
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

supplied() {
    local prompt words rev
    prompt="$(field prompt)"
    read -ra words <<<"${prompt%%$'\n'*}"
    [[ ${words[0]:-} == At ]] || return 1
    rev=${words[1]:-}
    rev=${rev%[,.:;]}
    [[ $rev =~ ^[0-9a-f]{7,40}$ ]] || return 1
    echo "$rev"
}

found() {
    fetched || true
    git rev-parse --verify --quiet "$1^{commit}" >/dev/null
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
    fetched || return 0
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
    said="$(dev/check.sh "$@" 2>&1)" && return
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
        parts) names+=("files the parts hold amiss") ;;
        index) names+=("an index that isn't written") ;;
        eval) names+=("failing evaluation tests") ;;
        leaks) names+=("leaks") ;;
        bats) names+=("failing bats tests") ;;
        *) names+=("failing $stage") ;;
        esac
    done
    printf '%s, ' "${names[@]}" | sed 's/, $//'
}

fetched() {
    git fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*' '+refs/stamped/*:refs/stamped/*' 2>/dev/null
}

# Policy: stamps are written against what the operator last stamped on the branch, or, while the
# branch has no refs/stamped, against the commit the turn started at, or else where the branch left
# main, so that what wasn't stamped is stamped again rather than left out.
base() {
    local branch ref
    if branch="$(git symbolic-ref --quiet --short HEAD)" &&
        ref="$(git rev-parse --verify --quiet "refs/stamped/$branch^{commit}")" &&
        git merge-base --is-ancestor "$ref" HEAD; then
        echo "$ref"
    elif [[ -f $TURN ]]; then
        cat "$TURN"
    else
        git merge-base HEAD "origin/${MAIN:-main}" 2>/dev/null || git merge-base HEAD "${MAIN:-main}" 2>/dev/null
    fi
}

UNBASED="no commit to stamp against: no refs/stamped/<branch> HEAD is on, no $TURN, and no main HEAD shares history with"

# Policy: turn-end has the turn go on to set right what it found, but only once a turn, lest the
# turn never end.
turn-end() {
    local start again="" before
    [[ $(field stop_hook_active) != true ]] || again=yes
    [[ ! -e $REFUSED ]] || return 0
    if [[ -f $TURN && $(git rev-parse HEAD) == "$(cat "$TURN")" && -z $(git status --porcelain) ]]; then
        return 0
    fi
    start="$(base)" || ended "turn-end finds $UNBASED."
    before="$(tree)"
    step dev/write.sh "$start" ||
        ended "$stepped fails, as below: fix it before you end the turn, or tell the user why you can't." "$said"
    if [[ $(tree) != "$before" ]]; then
        { step git add --all && step git commit --quiet -m turn-end; } ||
            ended "$stepped fails, as below: see to it, and commit and push what turn-end wrote." "$said"
    fi
    step git push --quiet -u origin HEAD || ended "git push fails, as below: see to it, and push the branch." "$said"
}

# Accommodating for the environment's own Stop hook, which runs beside turn-end and has the turn go
# on for commits turn-end is about to push: what the agent commits, turn-end sees to at once.
tool-end() {
    [[ -z $(git rev-list -n 1 HEAD --not --remotes) ]] || turn-end
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
    if [[ -e $REFUSED ]]; then
        echo "Work is refused this turn, so nothing is handed over: tell the user so."
        return
    elif ! start="$(base)"; then
        echo "hand-over finds $UNBASED."
        return
    fi
    if ! step dev/write.sh "$start"; then
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
# what a PostToolUse or Stop hook says only if it exits 2.
case $command in
session-start) session-start ;;
turn-start) turn-start ;;
tool-end) tool-end ;;
turn-end) turn-end ;;
hand-over) hand-over ;;
provision) provision ;;
esac
exit 0
