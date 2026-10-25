#!/usr/bin/env bash
set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

find-route() {
    local host=$1 port=${2:-22}

    # Let localhost through
    if [[ $host == localhost ]]; then
        echo "$host"
        return 0
    fi

    # Fast-path for IPs
    if ip route get "$host" &>/dev/null; then
        log success "$host:$port is up"
        echo "$host"
        return 0
    fi

    # Fast-path for dotted names (likely FQDNs)
    if [[ "$host" == *.* ]] && ping-port "$host" "$port"; then
        log success "$host:$port is up"
        echo "$host"
        return 0
    fi

    local fqdn
    while IFS= read -r namespace; do
        fqdn="$host.$namespace"
        log info "trying $fqdn..."
        if ping-port "$fqdn" "$port"; then
            log success "$fqdn is up"
            echo "$fqdn"
            return 0
        fi
    done < <(org-toml.sh "namespaces")
    die 1 "no contact with $host:$port"
}

ping-port() {
    nc -z -w2 "$1" "$2" &>/dev/null
}

find-route "$@"
