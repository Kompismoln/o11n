#!/usr/bin/env bash
# tools/bin/as.sh

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

agent=

cleanup() {
    rm -rf "$tmpdir"
    [[ -z $agent ]] || SSH_AGENT_PID=$agent ssh-agent -k >/dev/null
}
trap cleanup EXIT

as() {
    local identity
    org-exported
    identity=$(try o11n resolve "$1")
    mkdir -p "$tmpdir/keys"
    local key_file=$tmpdir/keys/$identity
    shift

    eval "$(ssh-agent -s)" > >(log info)
    agent=$SSH_AGENT_PID

    "$tools_root/bin/id-entities.sh" "$identity" cat-secret age-key >"$key_file"

    SOPS_AGE_KEY_FILE=$key_file "$tools_root/bin/id-entities.sh" "$identity" cat-secret ssh-key |
        ssh-add - 2> >(log info)

    SOPS_AGE_KEY_FILE=$key_file "$@"
}

as "$@"
