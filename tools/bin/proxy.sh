#!/usr/bin/env bash

set -euo pipefail

km_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$km_root/libexec/run-with.bash"

proxy() {
    local port=${PORT:-8080}
    "$km_root/bin/as.sh" proxy ssh -NTD "$port" "proxy@$(find-route.sh "$1")"
}

proxy "$@"
