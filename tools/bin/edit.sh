#!/usr/bin/env bash

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

edit() {
    local id=$1 backend_path
    org-exported
    o11n sops-yaml "$id" >"$tmpdir/.sops.yaml"
    backend_path=$PWD/$(try o11n path sops-file "$id")
    log info "editing $backend_path"
    log info ".sops.yaml $(cat "$tmpdir/.sops.yaml")"
    (cd "$tmpdir" && sops "$backend_path")
}

edit "$@"
