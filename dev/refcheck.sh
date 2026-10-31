#!/usr/bin/env bash
# Usage: dev/refcheck.sh, in a clone. Flags each reference a doc makes, outside its code blocks and what a stamp pending
# holds as signed, that doesn't resolve: a path in backticks whose first part is at the clone's root, and that git
# doesn't ignore as what a tool writes, or a commit that isn't on main. A reference the text says is elsewhere is left
# alone: after "former" or "<owner>/<repo>'s", or before "in <owner>/<repo>".
set -euo pipefail
. dev/files.bash

# Prints each reference of the doc $1 that the text doesn't say is elsewhere, as <kind> <line> <reference>, by paragraph
# of prose, so that what says a reference is elsewhere still says so once prettier wraps it onto another line.
references() {
    gawk '
        function elsewhere(text, start, end) {
            return substr(text, 1, start - 1) ~ /(\<former|[[:alnum:]_-]+\/[[:alnum:]_.-]+'"'"'s)[[:space:]]*`?$/ ||
                substr(text, end) ~ /^`?[[:space:]]+in [[:alnum:]_-]+\/[[:alnum:]_.-]+/
        }
        function line(text, at,   before) {
            before = substr(text, 1, at - 1)
            return first + gsub(/\n/, "&", before)
        }
        function paragraph(   text, rest, at, ref, before, after, commit) {
            if (!n) return
            text = lines
            rest = text
            at = 0
            while (match(rest, /`[[:alnum:]_.-]+\/[^`[:space:]<>${}]*`/)) {
                ref = substr(rest, RSTART + 1, RLENGTH - 2)
                if (!elsewhere(text, at + RSTART, at + RSTART + RLENGTH)) print "path", line(text, at + RSTART), ref
                at += RSTART + RLENGTH - 1
                rest = substr(rest, RSTART + RLENGTH)
            }
            rest = text
            at = 0
            while (match(rest, /[0-9a-f]+/)) {
                commit = substr(rest, RSTART, RLENGTH)
                before = substr(text, at + RSTART - 1, 1)
                after = substr(text, at + RSTART + RLENGTH, 1)
                if (RLENGTH >= 7 && RLENGTH <= 40 && commit ~ /[a-f]/ && commit ~ /[0-9]/ &&
                    before !~ /[[:alnum:]_\/.:-]/ && after !~ /[[:alnum:]_-]/ &&
                    !elsewhere(text, at + RSTART, at + RSTART + RLENGTH))
                    print "commit", line(text, at + RSTART), commit
                at += RSTART + RLENGTH - 1
                rest = substr(rest, RSTART + RLENGTH)
            }
            n = 0
        }
        {
            kept = 0
            if ($0 == "<<<<<<< signed") signed = 1
            else if ($0 == "=======" && signed) signed = 0
            else if ($0 ~ /^>>>>>>> / || signed) ;
            else if ($0 ~ /^[[:space:]]*```/) fenced = !fenced
            else if (!fenced && $0 ~ /[^[:space:]]/) {
                if (!n) first = NR
                lines = n ? lines "\n" $0 : $0
                n++
                kept = 1
            }
            if (!kept) paragraph()
        }
        END { paragraph() }
    ' "$1"
}

resolves() {
    local path=${1%%:*}
    git check-ignore -q "$path" && return
    local matches
    if [[ $path == *"*"* ]]; then
        # shellcheck disable=SC2206 # Policy: the path is a glob, which this expands.
        matches=($path)
        [[ -e ${matches[0]} ]]
    else
        [[ -e $path ]]
    fi
}

main=$(git rev-parse --verify -q origin/main || git rev-parse --verify -q main || :)
failed=0
while IFS= read -r -d '' doc; do
    refs=$(references "$doc")
    while read -r kind n ref; do
        [[ -n $kind ]] || continue
        if [[ $kind == path ]]; then
            if [[ -e ${ref%%/*} ]] && ! resolves "$ref"; then
                echo "flag: $doc:$n: \`$ref\` isn't there" >&2
                failed=1
            fi
        elif [[ -z $main ]] || ! git merge-base --is-ancestor "$ref" "$main" 2>/dev/null; then
            echo "flag: $doc:$n: $ref isn't a commit on main" >&2
            failed=1
        fi
    done <<<"$refs"
done < <(files '*.md')
((failed == 0))
