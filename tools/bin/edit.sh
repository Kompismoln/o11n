#!/usr/bin/env bash
# tools/bin/edit.sh

set -euo pipefail

declare -x entity class

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

edit() {
    declare -x class entity
    if IFS='-' read -r class entity < <(org-toml.sh autocomplete-identity "$1"); then
        org-toml.sh sops-yaml "$class-$entity" >"$tmpdir/.sops.yaml"
        backend_path=$PWD/$(CONTEXT="$class:$entity:age-key" org-toml.sh "secrets")
        log info "editing $backend_path"
        log info ".sops.yaml $(cat "$tmpdir/.sops.yaml")"
        (cd "$tmpdir" && sops "$backend_path")
    fi
}

edit "$@"
