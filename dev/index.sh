#!/usr/bin/env bash
# Usage: dev/index.sh [--check], from the clone's root. Writes docs/index/<part>.md for each part the flake's index
# (dev/index.nix) has entries for, and removes those of parts it has none for; with --check, writes nothing and flags,
# and fails for, each that differs from what it would write, its stamps pending read as written now.
set -euo pipefail

check=""
[[ ${1:-} != --check ]] || check=yes
index=docs/index

rendered() {
    jq -r --arg part "$1" '
        def default:
            (.default | trim) as $default
            | if .prose then ["", "Default: \($default)"]
              elif $default | contains("\n") then ["", "Default:", "", "```nix", $default, "```"]
              else ["", "Default: `\($default)`"] end;
        [
            "# `\($part)`",
            "",
            "Written by `dev/index.sh` from the options of an org that are declared in the part'"'"'s code, as `dev/index.nix` reads them, each by its place in `org.toml`.",
            "",
            "## Options",
            (.[$part][] | (
                "",
                "### `\(.name)`",
                "",
                ([(.files | map("`\(.)`") | join(", "))] + (if .type then [.type] else [] end) | join(" · ")),
                (if .default != null then default[] else empty end),
                (if .description then "", (.description | trim) else empty end)
            ))
        ] | join("\n")
    ' <<<"$said" | prettier --stdin-filepath "$index/$1.md"
}

said=$(nix eval --json --no-warn-dirty .#index)
mapfile -t parts < <(jq -r 'to_entries[] | select(.value != []) | .key' <<<"$said" | sort)
flagged=0
for part in "${parts[@]}"; do
    path=$index/$part.md
    text=$(rendered "$part")
    [[ ! -f $path || $(dev/stamps.sh applied "$path") != "$text" ]] || continue
    if [[ -n $check ]]; then
        echo "flag: $path: isn't what dev/index.sh writes"
        flagged=1
    else
        mkdir -p "$index"
        printf '%s\n' "$text" >"$path"
        echo "$path: written"
    fi
done
for path in "$index"/*.md; do
    [[ -f $path && " ${parts[*]} " != *" $(basename "$path" .md) "* ]] || continue
    if [[ -n $check ]]; then
        echo "flag: $path: indexes a part with nothing to index"
        flagged=1
    else
        rm "$path"
        echo "$path: removed"
    fi
done
((flagged == 0))
