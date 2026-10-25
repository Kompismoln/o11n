#!/usr/bin/env bash
# tools/bin/org-toml.sh
# shellcheck disable=SC2016
# - Yes, we know expressions wont expand in single quotes.

set -euo pipefail

declare -x class entity key slot

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

org-toml() {
    if declare -F "$1:" >/dev/null; then
        fn="$1:"
        shift
        $fn "$@"
        return
    fi

    local query='getpath($ARGS.positional) | if type == "array" then .[] else . end'
    as-json | try jq -re --args "$query" "$@"
}

public-artifacts:() {
    with key
    as-json | try jq -re '.["public-artifacts"] | (."'"$key"'" // .default)' | (
        with class entity key
        envsubst
    )
}

secrets:() {
    with class entity key

    local template='.secrets | (."$class" // .default)'
    query=$(echo "$template" | envsubst)
    as-json | try jq -r "$query" | envsubst
}

class-list:() {
    as-json | try jq -r ".class | keys[]"
}

ops:() {
    local query='.ops.'"$1"' | to_entries[] | .key as $k | .value[] | "\($k) \(. )"'
    as-json | try jq -r "$query" | while IFS=' ' read -r entity_group op; do
        expand-entity-group: "$entity_group" | while IFS='-' read -r _class _entity; do
            echo "$_class-$_entity $op"
        done
    done
}

sops-yaml:() {
    local c_class c_entity
    echo "creation_rules:"
    expand-entity-group: "$1" | (
        rc=0
        while IFS='-' read -r c_class c_entity; do
            path_regex="$(CONTEXT="$c_class:$c_entity:age-key" secrets:)"
            recipients=$(recipients: "$c_class-$c_entity") || rc=$?
            # shellcheck disable=SC2001
            cat <<EOF
  - path_regex: $path_regex
    key_groups:
      - age:
$(echo "$recipients" | sed 's/^/        - /')
EOF
        done
        exit $rc
    ) || log warning "some recipients missing" || exit 0
}

recipients:() {
    local t_class t_entity
    IFS='-' read -r t_class t_entity <<<"$1"
    {
        echo "$t_class-$t_entity"
        org-toml "root-identities"
        grants: "$1"
    } | sort -u | (
        local r_class r_entity
        rc=0
        log trace "$t_class-$t_entity"
        while IFS='-' read -r r_class r_entity; do
            log trace "$r_class-$r_entity"
            (id-key "$r_class" "$r_entity") || rc=$?
        done
        exit "$rc"
    ) || log warning "$t_class-$t_entity has missing recipients"
}

grants:() {
    local g_class g_entity e_class e_entity entity_group
    IFS='-' read -r g_class g_entity <<<"$1"
    local query='."'"$g_class"'".["'"$g_entity"'"].grants // [] | .[]'

    as-json | try jq -r "$query" | while IFS= read -r entity_group; do
        expand-entity-group: "$entity_group" | while IFS='-' read -r e_class e_entity; do
            echo "$e_class-$e_entity"
        done
    done
}

expand-entity-group:() {
    case $1 in
    "*")
        ids:
        ;;
    *-"*")
        IFS='-' read -r _class _ <<<"$1"
        ids-by-class: "$_class"
        ;;
    *:*)
        IFS=':' read -r _class entity_group <<<"$1"
        ids-by-roles: "$_class" "$entity_group"
        ;;
    *-*)
        echo "$1"
        ;;
    *)
        die 1 "bad argument '$1'"
        ;;
    esac
}

ids:() {
    org-toml.sh "class-list" | while read -r _class; do
        ids-by-class: "$_class"
    done

}

ids-by-id:() {
    local i_class i_entity
    IFS='-' read -r i_class i_entity <<<"$1"
    as-json | LOG_LEVEL=off try jq -re '."'"$i_class"'".["'"$i_entity"'"]' >/dev/null && echo "$i_class-$i_entity"
}

ids-by-class:() {
    if [[ $1 == "*" ]]; then
        org-toml "class-list" | while read -r _class; do
            ids-by-class "$_class"
        done
    else
        ids-by-class "$_class"
    fi
}

ids-by-class() {
    as-json | try jq -re ".$1 | keys | map(\"$1-\" + .) | .[]"
}

ids-by-substring:() {
    if [[ $1 == "*" ]]; then
        org-toml "class-list" | while read -r _class; do
            ids-by-substring "$_class" "$2"
        done
    else
        ids-by-substring "$@"
    fi
}

ids-by-substring() {
    local query='.'"$1"' | keys | map(. | "'"$1-"'" + select(contains("'"$2"'"))) | .[]'
    as-json | try jq -r "$query"
}

ids-by-roles:() {
    local r_class=$1
    IFS='+' read -r -a args <<<"$2"
    if [[ $1 == "*" ]]; then
        org-toml "class-list" | while read -r r_class; do
            ids-by-roles "$r_class" "${args[@]}"
        done
    else
        ids-by-roles "$r_class" "${args[@]}"
    fi
}

ids-by-roles() {
    query=".$1"' | to_entries[] | . as $entry | select(all($ARGS.positional[]; IN($entry.value.roles[]))) | "'"$1-"'"+.key'
    shift && as-json | try jq -r --args "$query" "$@"
}

autocomplete-identity:() {
    ids-by-id: "$1" && return
    local matches
    matches="$(LOG_LEVEL=off ids-by-substring: "*" "$1")"
    [[ -n "$matches" ]] || die 1 "\`$1\` did not match any identities"

    if (($(echo "$matches" | wc -l) > 1)); then
        die 1 "$matches"$'\n'"^ ambiguous result, which did you mean?"
    fi

    echo "$matches"
}

id-key() {
    local age_key_file
    age_key_file="$(CONTEXT="$1:$2:age-key" public-artifacts:)"
    try cat "$age_key_file"
}

as-json() {
    with repo_root
    [[ -s "$tmpdir/org.json" ]] ||
        toml2json <"$repo_root/org.toml" >"$tmpdir/org.json"
    try cat "$tmpdir/org.json"
}

class() {
    echo "$CONTEXT" | cut -d':' -f1
}

entity() {
    echo "$CONTEXT" | cut -d':' -f2
}

key() {
    echo "$CONTEXT" | cut -d':' -f3
}

slot() {
    echo "$CONTEXT" | cut -d':' -f4
}

org-toml "$@"
