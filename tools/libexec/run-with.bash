#!/usr/bin/env bash
# libexec/run-with.bash

[[ ${_RUN_WITH_BASH_SOURCED:-0} -eq 1 ]] && return
_RUN_WITH_BASH_SOURCED=1

tmpdir=$(mktemp -d)
declare -rx tmpdir
# shellcheck disable=SC2064
# - expanding $tmpdir immediately is the point
trap "rm -rf '$tmpdir'" EXIT

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
declare -x tools_root
tools_root="$(cd "$here/.." && pwd)"

# implement a function that maps a prefix to a list of (potential) functions
callchain() {
    die 1 "callchain for prefix '$prefix' not implemented"
}

# satisfy shellcheck
declare -g callchain

# for each prefix, run its' matching list of commands (call them links)
run() {
    local link links prefix

    for prefix; do
        # call callchain and bring it into scope as $callchain
        with callchain

        # call them "links" to distinguish from normal fns/cmds
        links=$(for link in $callchain; do
            # trailing colon terminates the callchain
            declare -F "$link:" && break
            # other matches are added in sequence
            declare -F "$link" || continue
        done)

        # life will be easier if we enforce this
        [[ -n $links ]] ||
            die 1 "'$prefix' didn't match any link in the callchain:"$'\n'"$(callchain)"

        for link in $links; do
            log debug "run $link"
            "$link"
        done
    done
}

# bring into scope the result of some-command as $some_command
with() {
    local cmd out var
    for cmd; do
        log trace "with $cmd"
        out=$(if [[ $cmd == *:* ]]; then
            run "$cmd"
        else
            "$cmd"
        fi) && {
            var="${cmd//[^a-zA-Z0-9_]/_}"
            declare -g "$var=$out"
        } || exit 1
    done
}

tlog() {
    local rc=$?
    tee >(log "$1")
    return $rc
}

log() {
    local rc=$?
    local label=${1:?"log needs a label"}

    local msg="${2:-$(cat)}"
    [[ -n "$msg" ]] || return 0

    local level c1 c2 c3
    IFS=' ' read -r level c1 c2 c3 <<<"${LOG_CONFIG[$label]}"

    [[ $level -ge ${LOG_CONFIG[${LOG_LEVEL:-info}]%% *} ]] ||
        return 0

    local backtrack=1
    while [[ ${FUNCNAME[$backtrack]} =~ ^(tlog|die|try|with|run)$ ]]; do
        ((backtrack++))
    done

    local caller=${FUNCNAME[$backtrack]}
    local depth=$((${#FUNCNAME[@]} - backtrack - 1))

    [[ "$msg" == *$'\n'* ]] && {
        msg=$'\n'"$msg"
        msg="${msg//$'\n'/$'\n    | '}"
    }

    printf "%b[%02d]: %b%s -> %b%s%b\n" \
        "$c1" "$depth" "$c2" "$caller" "$c3" "$msg" "$NC" >&2

    return $rc
}

die() {
    local exit_code=${1-$?}
    local msg=${2:-"died."}
    local fn=${3-}

    [[ -z "$fn" ]] || "$fn"

    case $exit_code in
    0) log success "$msg" ;;
    *) log error "$msg (exit $exit_code)" ;;
    esac

    exit "$exit_code"
}

try() {
    local std=$tmpdir/std.$$.$BASHPID
    touch "$std.out"
    chmod 600 "$std.out"

    local exit_code=0

    "$@" >"$std.out" 2>"$std.err" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log debug "try $*"
        log important <"$std.err"
        cat "$std.out"
    else
        cat "$std.out" >>"$std.err"
        die "$exit_code" "$(tr -d '\r' <"$std.err")"
    fi
}

links-by-prefix() {
    declare -F | awk '{print $3}' | grep -E "$1"
}

trailing-newline() {
    [[ $(tail -c1 "$1" | hexdump -C) == *"0a"* ]]
}

declare -g repo_root
repo_root() {
    local repo_root=${REPO_ROOT:-$(pwd)}
    [[ -d $repo_root ]] || die 1 "$repo_root is not a directory"
    echo "$repo_root"
}

RN='\033[0;31m'
RB='\033[1;31m'
GN='\033[0;32m'
GB='\033[1;32m'
YN='\033[0;33m'
YB='\033[1;33m'
BN='\033[0;34m'
BB='\033[1;34m'
MN='\033[0;35m'
MB='\033[1;35m'
CN='\033[0;36m'
CB='\033[1;36m'
WN='\033[0;37m'
WB='\033[1;37m'
NC='\033[0m'

declare -A LOG_CONFIG=(
    [trace]="0 $NC $WB $WN"
    [debug]="1 $NC $CB $CN"
    [info]="2 $NC $BB $BN"
    [warning]="3 $NC $YB $YN"
    [important]="3 $NC $YN $YB"
    [success]="4 $NC $GB $GN"
    [error]="4 $NC $RB $RN"
    [focus]="98 $MB $MB $MN"
    [off]="99"
)
