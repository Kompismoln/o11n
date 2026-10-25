#!/usr/bin/env bash
set -euo pipefail
tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

declare -g cloudaccount domainname apikey endpoint

cloudaccount() {
    org-toml.sh service glesys-api data account
}

endpoint() {
    org-toml.sh service glesys-api endpoint
}

domainname() {
    org-toml.sh domain
}

apikey() {
    id-entities.sh -s glesys-api cat-secret secret-key
}

#recordid="3357682"
#user="$account:$secret"
#data="recordid=$recordid&data=asdf"
#ip -4 -o addr show "wlp3s0" | awk '{split($4, a, "/"); print a[1]}'
#curl -sSX POST -d "$data" -u "$user" ${endpoint}

glesys-api() {
    if declare -F "$1:" >/dev/null; then
        fn="$1:"
        shift
        $fn "$@"
        return
    fi
}

recordid:() {
    with domainname cloudaccount apikey endpoint
    local url="$endpoint/domain/listrecords?domainname=$domainname"
    local path="//response/records/item[host='$1']/recordid/text()"
    xmllint --xpath "$path" <(curl -sSX GET -u "$cloudaccount:$apikey" "$url")
}

glesys-api "$@"
