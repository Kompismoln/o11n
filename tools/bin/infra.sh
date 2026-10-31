#!/usr/bin/env bash

set -uo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

for-all-identities() {
    local id op action key
    org-exported
    if [[ $1 == "updatekeys" ]]; then
        o11n reencrypt
        return
    fi
    o11n ops "$1" | while IFS=" " read -r id op; do
        [[ "$id" != "root-"* ]] || continue
        IFS=':' read -r action key <<<"$op"
        case $action in
        verify) o11n public-key verify "$id" "$key" ;;
        check) o11n host check "$id" "$key" ;;
        rebuild) o11n reencrypt ;;
        *) die 1 "$op: no such op" ;;
        esac
    done
}

for-all-identities "$@"
