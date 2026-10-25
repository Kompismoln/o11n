#!/usr/bin/env bash
# Usage: stamps write | stamps check [dir]
#
# A stamp pending is a git conflict in a Markdown file, from `<<<<<<< signed` to `=======` as a
# human last signed it and on to the `>>>>>>>` closing it as written now: a human stamps it.
# `stamps write`, in a clone, writes one around each change since the latest commit on HEAD's
# first parents that someone else made. `stamps check` fails while one is pending, or on a
# conflict marker that isn't a stamp's, in a clone or in a directory without git.
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

write() {
    cd "$(git rev-parse --show-toplevel)"
    local mine base path was written=0
    mine=$(git var GIT_AUTHOR_IDENT | sed 's/.*<\(.*\)>.*/\1/')
    base=$(git log --first-parent --format='%H %ae' | awk -v mine="$mine" '!found && $2 != mine { print $1; found = 1 }')
    [[ -n $base ]] ||
        die "write: no commit on HEAD's first parents is by anyone but $mine, so nothing says what a human signed"
    echo "against $(git log -1 --format='%h %s' "$base")"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

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
        restamp "$path" "$was" "$base" && written=1
    done < <(git diff -z --name-status -M "$base" -- '*.md')

    while IFS= read -r -d '' path; do
        restamp "$path" "" "$base" && written=1
    done < <(git ls-files -z --others --exclude-standard -- '*.md')

    ((written)) || echo "nothing to write"
}

restamp() {
    local path=$1 was=$2 base=$3
    : >"$tmp/then"
    if [[ -n $was ]]; then
        git show "$base:$was" >"$tmp/signed"
        side signed "$was at $base" "$tmp/signed" >"$tmp/then" || exit 1
    fi
    side applied "$path" "$path" >"$tmp/now" || exit 1
    marked "$tmp/then" "$tmp/now" >"$tmp/written"
    cmp -s "$tmp/written" "$path" && return 1
    cat "$tmp/written" >"$path"
    echo "$path: $(grep -cxF "$opening" "$path" || :) stamps"
}

check() {
    cd "${1:-.}"
    local path n why flagged=0
    while IFS= read -r -d '' path; do
        path=${path#./}
        [[ -f $path ]] || continue
        if ! why=$(side applied "$path" "$path" 2>&1 >/dev/null); then
            echo "flag: $why" >&2
            flagged=1
            continue
        fi
        n=$(grep -cxF "$opening" "$path" || :)
        if ((n > 0)); then
            echo "flag: $path: $n stamps pending: a human stamps them before work proceeds" >&2
            flagged=1
        fi
    done < <(documents)
    ((flagged == 0)) || exit 1
    echo ok
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
check) check "${2:-}" ;;
*) die "usage: stamps write | stamps check [dir]" ;;
esac
