#!/usr/bin/env bash

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

proxy() {
    local port=${PORT:-8080}
    "$tools_root/bin/as.sh" proxy ssh -NTD "$port" "proxy@$(find-route.sh "$1")"
}

proxy "$@"
