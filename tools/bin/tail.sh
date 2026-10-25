#!/usr/bin/env bash

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

login() {
    "$tools_root/bin/as.sh" "${1%%@*}" "ssh" "$1" "journalctl -ef"
}

login "$@"
