#!/usr/bin/env bash

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
    local id=$1 key_file=$tmpdir/keys/$1
    shift
    org-exported
    mkdir -p "$tmpdir/keys"

    eval "$(ssh-agent -s)" > >(log info)
    agent=$SSH_AGENT_PID

    (umask 077 && try o11n identity show "$id" >"$key_file")

    SOPS_AGE_KEY_FILE=$key_file try o11n secret show "$id" ssh-key | ssh-add - 2> >(log info)

    SOPS_AGE_KEY_FILE=$key_file "$@"
}

as "$@"
