# shellcheck shell=bash
# Usage: . dev/files.bash, as dev/check.sh and dev/write.sh do, so that what format checks is what write.sh
# writes.

files() {
    local pattern path
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files -z --cached --others --exclude-standard -- "$@"
    else
        for pattern in "$@"; do
            find . -type f -path "./$pattern" -printf '%P\0'
        done
    fi | while IFS= read -r -d '' path; do
        if [[ -f $path ]]; then printf '%s\0' "$path"; fi
    done
}

# Policy: prettier leaves a doc that holds stamps pending as it is, as it would read their markers
# as markdown, till it is stamped.
unheld() {
    local doc
    files '*.md' | while IFS= read -r -d '' doc; do
        if ! grep -qxF '>>>>>>> @''stamp' "$doc"; then printf '%s\0' "$doc"; fi
    done
}
