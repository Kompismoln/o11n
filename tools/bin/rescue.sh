#!/usr/bin/env bash

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

rescue() {
    target_address=$(find-route.sh "$1")
    "$tools_root/bin/as.sh" "rescue" "ssh" "root@$target_address"
}

rescue "$@"
