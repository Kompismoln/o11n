#!/usr/bin/env bash

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

inject-unit() {
    unit=${1:?"unit required"}
    host=${2:?"host required"}
    source_config=${3:-$host}

    module=".#nixosConfigurations.$source_config.config.systemd.units.\"$unit\".text"
    target_address=$(find-route.sh "$host")

    if [[ $# -eq 2 ]]; then
        nix eval --raw "$module" || die 1 "not a unit: $module"
        exit 0
    else
        # shellcheck disable=SC2029
        nix eval --raw "$module" >"$tmpdir/$unit" 2>/dev/null || die 1 "not a unit: $module"
        as.sh rescue scp "root@$target_address" "$tmpdir/$unit" "/run/systemd/system/$unit"
    fi

}

inject-unit "$@"
