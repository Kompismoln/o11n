#!/usr/bin/env bash
# Usage: stamps write | stamps check [--baseline] [dir]
#
# A stamp pending is a git conflict in a Markdown file, from `<<<<<<< signed` to `=======` as a
# human last signed it and on to the `>>>>>>>` closing it as written now: a human stamps it.
# `stamps write`, in a clone, writes one around each change since what a human last signed.
# `stamps check` fails on a conflict marker that isn't a stamp's, and in a clone on stamps that
# aren't written; it flags the stamps pending, and with --baseline fails on them too. It reads a
# clone or a directory without git.
set -euo pipefail

opening="<<<<<<< signed"
divider="======="
# Policy: never spelled whole, so that a search for it finds the stamps pending alone.
closing=">>>>>>> @""stamp"

die() {
    echo "stamps: $1" >&2
    exit 1
}

side() {
    awk -v side="$1" -v name="$2" -v opening="$opening" -v divider="$divider" -v closing="$closing" '
        function fail(n, why) { printf "%s: line %d: %s\n", name, n, why > "/dev/stderr"; failed = 1; exit 1 }
        at == "" && $0 == opening { at = "signed"; opened = NR; next }
        at == "signed" && $0 == divider { at = "applied"; next }
        at == "applied" && $0 == closing { at = ""; next }
        /^(<<<<<<<|>>>>>>>)/ { fail(NR, "a conflict marker that isn'\''t a stamp'\''s") }
        at == "" || at == side { print }
        END { if (!failed && at != "") fail(opened, "a stamp isn'\''t closed") }
    ' "$3"
}

marked() {
    diff --unchanged-group-format=%= \
        --old-group-format="$opening"$'\n'%\<"$divider"$'\n'"$closing"$'\n' \
        --new-group-format="$opening"$'\n'"$divider"$'\n'%\>"$closing"$'\n' \
        --changed-group-format="$opening"$'\n'%\<"$divider"$'\n'%\>"$closing"$'\n' \
        "$1" "$2" || [[ $? -eq 1 ]]
}

# Sets base to what a human last signed: the latest commit on HEAD's first parents that someone
# else made, or, with O11N_DEV set as on the human's side, that you made; and signer to who that is.
find-base() {
    local mine commits
    mine=$(git var GIT_AUTHOR_IDENT | sed 's/.*<\(.*\)>.*/\1/')
    commits=$(git log --first-parent --format='%H %ae' 2>/dev/null) || commits=
    if [[ -n ${O11N_DEV:-} ]]; then
        signer=$mine
        base=$(awk -v mine="$mine" '!found && $2 == mine { print $1; found = 1 }' <<<"$commits")
    else
        signer="anyone but $mine"
        base=$(awk -v mine="$mine" '!found && $2 != mine { print $1; found = 1 }' <<<"$commits")
    fi
    [[ -n $base ]]
}

# Calls $1 with each document changed since base, and the path it had then, if any.
changes() {
    local status path was
    while IFS= read -r -d '' status; do
        case $status in
        R*) IFS= read -r -d '' was && IFS= read -r -d '' path ;;
        A) IFS= read -r -d '' path && was= ;;
        M | T) IFS= read -r -d '' path && was=$path ;;
        *)
            IFS= read -r -d '' _
            continue
            ;;
        esac
        "$1" "$path" "$was"
    done < <(git diff -z --name-status -M "$base" -- '*.md')

    while IFS= read -r -d '' path; do
        "$1" "$path" ""
    done < <(git ls-files -z --others --exclude-standard -- '*.md')
}

# Writes to $tmp/written the document $1 with a stamp around each change since base, against $2
# as it was then.
stamped() {
    local path=$1 was=$2
    : >"$tmp/then"
    if [[ -n $was ]]; then
        git show "$base:$was" >"$tmp/signed"
        side signed "$was at $base" "$tmp/signed" >"$tmp/then" || exit 1
    fi
    side applied "$path" "$path" >"$tmp/now" || exit 1
    marked "$tmp/then" "$tmp/now" >"$tmp/written"
}

restamp() {
    stamped "$@"
    cmp -s "$tmp/written" "$1" && return
    cat "$tmp/written" >"$1"
    echo "$1: $(grep -cxF "$opening" "$1" || :) stamps"
    written=1
}

unwritten() {
    stamped "$@"
    cmp -s "$tmp/written" "$1" && return
    echo "flag: $1: stamps aren't written: run write-stamps" >&2
    behind=1
}

write() {
    cd "$(git rev-parse --show-toplevel)"
    local base signer written=0
    find-base || die "write: no commit on HEAD's first parents is by $signer, so nothing says what a human signed"
    echo "against $(git log -1 --format='%h %s' "$base")"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    changes restamp
    ((written)) || echo "nothing to write"
}

check() {
    local baseline=0
    if [[ ${1:-} == --baseline ]]; then
        baseline=1
        shift
    fi
    cd "${1:-.}"
    local path n why flagged=0 failed=0
    while IFS= read -r -d '' path; do
        path=${path#./}
        [[ -f $path ]] || continue
        if ! why=$(side applied "$path" "$path" 2>&1 >/dev/null); then
            echo "flag: $why" >&2
            failed=1
            continue
        fi
        n=$(grep -cxF "$opening" "$path" || :)
        if ((n > 0)); then
            echo "flag: $path: $n stamps pending: a human stamps them before work proceeds" >&2
            flagged=1
            ((baseline == 0)) || failed=1
        fi
    done < <(documents)

    local base signer behind=0
    if ((failed == 0)) && git rev-parse --git-dir >/dev/null 2>&1 && find-base; then
        cd "$(git rev-parse --show-toplevel)"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        changes unwritten
        ((behind == 0)) || failed=1
    fi
    ((failed == 0)) || exit 1
    ((flagged)) || echo ok
}

documents() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files -z --cached --others --exclude-standard -- '*.md'
    else
        find . -name '*.md' -not -path '*/.git/*' -print0
    fi
}

case ${1:-} in
write) write ;;
check)
    shift
    check "$@"
    ;;
*) die "usage: stamps write | stamps check [--baseline] [dir]" ;;
esac
