#!/usr/bin/env bash
# Usage: stamps write <commit> | stamps check [dir] | stamps pending [dir]
#
# A stamp pending is a git conflict in a Markdown file, from `<<<<<<< signed` to `=======` as the
# operator last signed it and on to the `>>>>>>>` closing it as written now: the operator stamps it.
# `stamps write`, in a clone, writes one around each change to a doc since the commit, against what
# the operator had signed of it there. `stamps check` flags a conflict marker that isn't a stamp's
# and a stamp that isn't closed, and `stamps pending` the stamps pending as well; each fails if it
# flags any, and reads a clone or a directory without git.
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

write() {
    cd "$(git rev-parse --show-toplevel)"
    local base written=0
    base=$(git rev-parse --verify -q "${1:-}^{commit}") || die "write: '${1:-}' isn't a commit"
    echo "against $(git log -1 --format='%h %s' "$base")"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    changes restamp
    ((written)) || echo "nothing to write"
}

# Flags each document's conflict markers that aren't a stamp's or aren't closed, and with $1 set its
# stamps pending, and fails if it flags any.
scan() {
    local pending=$1 path why n failed=0
    cd "${2:-.}"
    while IFS= read -r -d '' path; do
        path=${path#./}
        [[ -f $path ]] || continue
        if ! why=$(side applied "$path" "$path" 2>&1 >/dev/null); then
            echo "flag: $why" >&2
            failed=1
        elif ((pending)) && n=$(grep -cxF "$opening" "$path"); then
            echo "flag: $path: $n stamps pending: the operator stamps them before work proceeds" >&2
            failed=1
        fi
    done < <(documents)
    ((failed == 0))
}

documents() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files -z --cached --others --exclude-standard -- '*.md'
    else
        find . -name '*.md' -not -path '*/.git/*' -print0
    fi
}

case ${1:-} in
write) write "${2:-}" ;;
check) scan 0 "${2:-}" ;;
pending) scan 1 "${2:-}" ;;
*) die "usage: stamps write <commit> | stamps check [dir] | stamps pending [dir]" ;;
esac
