#!/usr/bin/env bash
# Usage: ./dev/agent.sh session-start | turn-start | tool-end | turn-end | hand-over
#        | fetch-inputs [flake.lock] | lix-daemon <dir>.
# The hooks of .claude/settings.json run session-start to turn-end, with a hook's JSON on stdin.
# Each says nothing unless the agent has something to do, and exits 0, but tool-end and turn-end,
# which exit 2 to tell the agent. hand-over runs at request "hand over"; fetch-inputs and lix-daemon
# are the agent's tools, for a session's network and for a store of its own.
set -euo pipefail

USAGE="usage: ./dev/agent.sh session-start | turn-start | tool-end | turn-end | hand-over | fetch-inputs [flake.lock] | lix-daemon <dir>"

# Accommodating for a session's network, which refuses or rate-limits the forges' archives: an input
# fetched over git at its locked revision lands at the path nix's github: or gitlab: fetcher would
# make, so nix finds it there.
fetch-inputs() {
    local refs ref json log failed=0
    refs=$(
        jq -r '
            {github: "github.com", gitlab: "gitlab.com"} as $hosts
            | [.nodes[].locked // empty | select(.type // "" | in($hosts)) | [.host // $hosts[.type], .owner, .repo, .rev]]
            | unique[]
            | "git+https://\(.[0])/\(.[1])/\(.[2])?rev=\(.[3])&shallow=1"
        ' "$1"
    )
    log=$(mktemp)
    for ref in $refs; do
        if json=$(nix flake prefetch --json "$ref" 2>"$log"); then
            jq -r .storePath <<<"$json"
        else
            echo "fetch-inputs: could not fetch $ref:" >&2
            cat "$log" >&2
            failed=1
        fi
    done
    rm -f "$log"
    return "$failed"
}

# Accommodating for the session: Lix's daemon listens on /nix/var/nix/daemon-socket/socket unless
# told otherwise, where the session's own nix, with store = auto, would take it for its daemon; and
# Lix gives fixed-output fetches their network through pasta, which can't start here.
lix-daemon() {
    local dir=${1:?usage: ./dev/agent.sh lix-daemon <dir>} lix
    mkdir -p "$dir"
    dir=$(cd "$dir" && pwd)
    [[ ! -S $dir/socket ]] || {
        echo "lix-daemon: $dir/socket is there already: kill \"\$(cat $dir/pid)\" first" >&2
        return 1
    }

    lix=$(nix build --no-link --print-out-paths "$(git rev-parse --show-toplevel)#nixpkgs.legacyPackages.x86_64-linux.lix" | grep -v -- '-man$')

    NIX_REMOTE="local?root=$dir/root" \
        NIX_DAEMON_SOCKET_PATH=$dir/socket \
        NIX_CONFIG="pasta-path =
extra-experimental-features = daemon-trust-override
${NIX_CONFIG:-}" \
        setsid "$lix/bin/nix-daemon" --force-untrusted >"$dir/log" 2>&1 </dev/null &
    echo $! >"$dir/pid"

    for _ in {1..100}; do
        if [[ -S $dir/socket ]]; then
            echo "unix://$dir/socket"
            return 0
        fi
        kill -0 "$(cat "$dir/pid")" 2>/dev/null || break
        timeout 0.1 tail -f /dev/null || true
    done
    echo "lix-daemon: the daemon didn't start:" >&2
    cat "$dir/log" >&2
    return 1
}

command=${1:-}
case $command in
session-start | turn-start | tool-end | turn-end | hand-over | provision) ;;
fetch-inputs)
    fetch-inputs "${2:-flake.lock}"
    exit
    ;;
lix-daemon)
    lix-daemon "${2:-}"
    exit
    ;;
*)
    echo "$USAGE" >&2
    exit 1
    ;;
esac

event=""
case $command in
session-start | turn-start | tool-end | turn-end) [[ -t 0 ]] || event="$(cat)" ;;
esac

cd "$(git rev-parse --show-toplevel)"

STATE=dev/state
ENV=$STATE/env
ROOTS=$STATE/roots
LOGS=$STATE/logs
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
if [[ -z ${O11N_ROOT:-} && -f crates/o11n-dev/Cargo.toml ]]; then
    export O11N_ROOT=$PWD
fi

# Policy: what settings.toml has each hook refuse work for and tell of is read where errexit holds,
# so that a settings.toml or an o11n-dev amiss stops the hook rather than have it check nothing, and
# once the session is provisioned, as o11n-dev comes with that.
declare -A REFUSES TELLS
configure() {
    local hook
    for hook in session-start turn-start; do
        REFUSES[$hook]="$(o11n-dev hook "$hook" refuse)"
        TELLS[$hook]="$(o11n-dev hook "$hook" tell)"
    done
    TELLS[hand-over]="$(o11n-dev hook hand-over tell)"
}

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
        configure
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
    remote && [[ -n ${O11N_REMOTE_BUILDER:-} ]] && command -v o11n >/dev/null || return 0
    said="$(timeout 120 o11n remote info 2>&1)" && return
    echo "Tell the user that the remote builder, $O11N_REMOTE_BUILDER, doesn't answer, as below, so nothing can be built on it this session, and go on."
    echo "$said"
}

session-checked() {
    hook-checked session-start
}

# Accommodating for bash, which ignores errexit wherever a status is tested: provisioning runs as a
# process of its own, so that it still stops at its first failure.
provisioned() {
    provisions && return
    refuse "a container that fails to provision" details
    echo "$said"
    return 1
}

provisions() {
    said="$(bash "${BASH_SOURCE[0]}" provision 2>&1)" || return
    # shellcheck source=/dev/null
    . "$ENV"
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
    inputs="$(fetch-inputs flake.lock)"
    for path in $inputs; do
        nix-store --quiet --add-root "$ROOTS/input-$((i++))" --realise "$path" >/dev/null
    done
    nix print-dev-env --quiet --no-warn-dirty --profile "$ROOTS/dev-shell" --json |
        jq -r '"export PATH=\(.variables.PATH.value | @sh):\"$PATH\""' >"$ENV"
    [[ -z ${O11N_ROOT:-} ]] || printf 'export O11N_ROOT=%q\n' "$O11N_ROOT" >>"$ENV"
    [[ -z ${CLAUDE_ENV_FILE:-} ]] || cat "$ENV" >>"$CLAUDE_ENV_FILE"
}

turn-start() {
    local state=() refused="" was rev
    if [[ -f $STARTED ]]; then
        read -ra state <"$STARTED"
        rm -f "$STARTED"
    fi
    [[ " ${state[*]} " != *" refused "* ]] || refused=refused
    [[ " ${state[*]} " == *" unprovisioned "* ]] || configure
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
    hook-checked turn-start
}

hook-checked() {
    local refuses=() tells=() refusing=() telling=() stage
    read -ra refuses <<<"${REFUSES[$1]}"
    read -ra tells <<<"${TELLS[$1]}"
    checked "${refuses[@]}" "${tells[@]}"
    ((${#failed[@]})) || return 0
    for stage in "${failed[@]}"; do
        if [[ " ${refuses[*]} " == *" $stage "* ]]; then
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

# Policy: a stage failed unless dev/check.sh's JSON beside its log, which this removes beforehand, says
# it passed, and all failed if it failed and none says so.
checked() {
    local stage
    failed=()
    (($#)) || return 0
    for stage in "$@"; do
        rm -f "$LOGS/$stage.json"
    done
    said="$(dev/check.sh "$@" 2>&1)" && return
    for stage in "$@"; do
        [[ $(jq -r .status "$LOGS/$stage.json" 2>/dev/null) == 0 ]] || failed+=("$stage")
    done
    ((${#failed[@]})) || failed=("$@")
}

sections() {
    local stage logged=0
    for stage in "${failed[@]}"; do
        [[ -f $LOGS/$stage.json ]] || continue
        tail -n +2 "$LOGS/$stage.log"
        logged=1
    done
    ((logged)) || echo "$said"
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

# Policy: turn-end has the turn go on to set right what it found, but only once a turn, lest the
# turn never end.
turn-end() {
    local start again="" before
    [[ $(field stop_hook_active) != true ]] || again=yes
    [[ ! -e $REFUSED ]] || return 0
    if [[ -f $TURN && $(git rev-parse HEAD) == "$(cat "$TURN")" && -z $(git status --porcelain) ]]; then
        return 0
    fi
    if remote && [[ ! -f $ENV ]]; then
        provisions || ended "turn-end provisions the session, which fails, as below: see to it, and commit and push the branch." "$said"
    fi
    start="$(o11n-dev base 2>&1)" || ended "turn-end finds ${start#o11n-dev: }."
    before="$(tree)"
    step env STAMPED="$start" dev/write.sh ||
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
    local start tells=() again="fix it and run ./dev/agent.sh hand-over again."
    if [[ -e $REFUSED ]]; then
        echo "Work is refused this turn, so nothing is handed over: tell the user so."
        return
    elif ! start="$(o11n-dev base 2>&1)"; then
        echo "hand-over finds ${start#o11n-dev: }."
        return
    fi
    configure
    if ! step env STAMPED="$start" dev/write.sh; then
        printf '%s\n' "$stepped fails, as below: $again" "$said"
        return
    fi
    if ! { step git add --all && { git diff --cached --quiet || step git commit --quiet -m hand-over; }; } ||
        ! step git push --quiet -u origin HEAD; then
        printf '%s\n' "$stepped fails, as below: see to it, and commit and push the branch." "$said"
        return
    fi
    read -ra tells <<<"${TELLS[hand-over]}"
    checked "${tells[@]}"
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
