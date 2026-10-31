#!/usr/bin/env bash
# Usage: dev/parts.sh, from the clone's root. Flags, and fails for, what dev/parts.toml holds amiss: a stage or a layer
# that isn't one of its stages or layers, a part's code or doc that isn't there, a tracked file two parts hold, and an
# index of no part.
set -euo pipefail
. dev/files.bash

flags=$(
    files '*' | jq -rRs --argjson declared "$(toml2json dev/parts.toml)" '
        def holds($entry): . == $entry or startswith(($entry | rtrimstr("/")) + "/");
        def said: if . == null then "None" else "'"'"'\(.)'"'"'" end;
        (split("\u0000") | map(select(. != ""))) as $files
        | $declared.parts as $parts
        | (
            $parts | to_entries[] | .key as $name | .value as $part
            | (if ($declared.stages | index([$part.stage])) then empty
               else "[parts.\($name)]: stage \($part.stage | said) isn'"'"'t one of stages" end),
              (if ($declared.layers | index([$part.layer])) then empty
               else "[parts.\($name)]: layer \($part.layer | said) isn'"'"'t one of layers" end),
              ($part.code // [] | .[] as $entry
               | if any($files[]; holds($entry)) then empty else "[parts.\($name)]: `\($entry)` isn'"'"'t there" end),
              (if $part.doc != null and ($files | index([$part.doc]) | not)
               then "[parts.\($name)]: `\($part.doc)` isn'"'"'t there" else empty end)
          ),
          (
            $files[] as $path
            | [$parts | to_entries[] | select($path == .value.doc or $path == "docs/index/\(.key).md") | .key]
              + [$parts | to_entries[] | select(any(.value.code // [] | .[]; . as $entry | $path | holds($entry))) | .key]
            | (if length > 1 then "`\($path)` is held by \(length) parts, \(join(", ")), not one" else empty end),
              (if ($path | startswith("docs/index/")) and length == 0 then "`\($path)` indexes no part" else empty end)
          )
        | "flag: dev/parts.toml: \(.)"
    '
)
[[ -z $flags ]] || {
    echo "$flags"
    exit 1
}
