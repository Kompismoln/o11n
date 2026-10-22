#!/usr/bin/env bash
# tools/bin/nix-remote.sh
#
# Builds on a host with the remote-builder role, through its endpoint on 443:
#
#   nix-remote.sh info
#   nix-remote.sh build <installable>... [nix build options]
#   nix-remote.sh check [flake] [nix build options]
#
# O11N_REMOTE_BUILDER is the host's URL (https://<endpoint>). The bearer token is read
# from O11N_REMOTE_BUILDER_TOKEN, or left to a proxy that adds the header itself.
# Evaluation happens here and the host builds. The outputs stay on the host and
# can't be read from here, so the build logs are printed as they come.
#
# gost carries the connection over plain HTTP requests (PHT), through HTTPS_PROXY when
# it is set. Where only that proxy resolves names, gost needs o11n's patch (o11n#gost).

set -euo pipefail

km_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$km_root/libexec/run-with.bash"

# As nixos/org/remote-builder.nix sets it.
path_prefix=nix-daemon

socket=$tmpdir/nix-daemon.sock
tunnel_log=$tmpdir/gost.log
tunnel_pid=

cleanup() {
    [[ -z $tunnel_pid ]] || kill "$tunnel_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

gost-config() {
    local url=${O11N_REMOTE_BUILDER:?"set O11N_REMOTE_BUILDER to the builder's https:// URL"}
    local proxy=${HTTPS_PROXY:-${https_proxy:-}}
    local server=${url#*://}
    server=${server%%/*}
    [[ $server == *:* ]] || server=$server:443
    proxy=${proxy#*://}
    proxy=${proxy%%/*}

    cat <<EOF
log:
  level: warn
services:
  - name: nix-daemon
    addr: $socket
    listener:
      type: unix
    handler:
      type: unix
      chain: builder
chains:
  - name: builder
    hops:
EOF
    [[ -z $proxy ]] || cat <<EOF
      - name: proxy
        nodes:
          - name: proxy
            addr: $proxy
            connector:
              type: http
            dialer:
              type: tcp
EOF
    cat <<EOF
      - name: builder
        nodes:
          - name: builder
            addr: $server
            connector:
              type: relay
            dialer:
              type: phts
              tls:
                secure: true
                serverName: ${server%:*}
              metadata:
                pushPath: /$path_prefix/push
                pullPath: /$path_prefix/pull
EOF
    [[ -z ${O11N_REMOTE_BUILDER_TOKEN:-} ]] || cat <<EOF
                header:
                  Authorization: 'Bearer $O11N_REMOTE_BUILDER_TOKEN'
EOF
}

# gost logs nothing when the tunnel's requests fail, so ask the endpoint once, the same
# way: a path under the prefix that the builder's gost doesn't serve answers 404.
diagnose() {
    local server=${O11N_REMOTE_BUILDER#*://}
    local url=https://${server%%/*}/$path_prefix/probe
    local args=(-sS -o /dev/null -w '%{http_code}' --max-time 20)
    local answer

    command -v curl >/dev/null || return 0
    if [[ -n ${O11N_REMOTE_BUILDER_TOKEN:-} ]]; then
        (umask 077 && echo "Authorization: Bearer $O11N_REMOTE_BUILDER_TOKEN" >"$tmpdir/headers")
        args+=(-H "@$tmpdir/headers")
    fi

    answer=$(curl "${args[@]}" "$url" 2>&1) || true
    case $answer in
    404) log info "$url answers as it should, so the tunnel itself failed" ;;
    401) log error "$url: the bearer token is missing or wrong" ;;
    *) log error "$url: $answer" ;;
    esac
}

start-tunnel() {
    command -v gost >/dev/null || die 1 "gost is not on PATH"

    (umask 077 && gost-config >"$tmpdir/gost.yaml")
    HOME=$tmpdir gost -C "$tmpdir/gost.yaml" >"$tunnel_log" 2>&1 &
    tunnel_pid=$!

    for _ in {1..50}; do
        [[ -S $socket ]] && return
        kill -0 "$tunnel_pid" 2>/dev/null || break
        sleep 0.1
    done
    tail -n 20 "$tunnel_log" >&2
    die 1 "gost didn't start"
}

store-info() {
    local cmd=info
    # Lix, forked before `nix store info`, still calls it ping.
    [[ $(nix --version) != *Lix* ]] || cmd=ping
    start-tunnel
    nix store "$cmd" --store "unix://$socket" "$@"
}

remote-build() {
    start-tunnel
    nix build --store "unix://$socket" --eval-store auto --no-link -L "$@"
}

# nix flake check --store asks the store which checks it would build before it has the
# derivations, so it builds none of them and passes; build each check instead.
remote-check() {
    local flake=. system
    if [[ -n ${1:-} && $1 != -* ]]; then
        flake=$1
        shift
    fi
    system=$(nix eval --raw --impure --expr builtins.currentSystem)

    local checks=()
    mapfile -t checks < <(
        nix eval --json "$flake#checks.$system" --apply builtins.attrNames | jq -r '.[]'
    )
    [[ ${#checks[@]} -gt 0 ]] || die 1 "$flake has no checks for $system"
    log info "checks: ${checks[*]}"

    remote-build "${checks[@]/#/$flake#checks.$system.}" "$@"
}

nix-remote() {
    local cmd=${1:-}
    local rc=0
    shift || true

    case $cmd in
    info) store-info "$@" || rc=$? ;;
    build) remote-build "$@" || rc=$? ;;
    check) remote-check "$@" || rc=$? ;;
    *) die 1 "usage: nix-remote.sh info | build <installable>... | check [flake]" ;;
    esac

    if [[ $rc -ne 0 ]]; then
        tail -n 20 "$tunnel_log" >&2
        diagnose
    elif [[ $cmd != info ]]; then
        log success "built on $O11N_REMOTE_BUILDER"
    fi
    return "$rc"
}

nix-remote "$@"
