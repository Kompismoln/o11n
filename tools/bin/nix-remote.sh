#!/usr/bin/env bash
# Usage: builds on a host with the remote-builder role, through its endpoint on 443:
#
#   nix-remote.sh info
#   nix-remote.sh build <installable>... [nix build options]
#   nix-remote.sh check [flake] [nix build options]
#   nix-remote.sh eval <stage> [o11n revision]
#
# O11N_REMOTE_BUILDER is the host's name, a scheme before it ignored. The bearer token is read
# from O11N_REMOTE_BUILDER_TOKEN, or left to a proxy that adds the header itself.
# Evaluation happens here and the host builds. The outputs stay on the host and
# can't be read from here, so the build logs are printed as they come.
#
# eval, from an org's clone, has the host evaluate and build a stage of the org at HEAD,
# with o11n at the revision given: both pushed, for the host fetches them itself.
#
# gost carries the connection over plain HTTP requests (PHT), through HTTPS_PROXY when
# it is set. Where only that proxy resolves names, gost needs o11n's patch (o11n#gost).

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

# Duplication: as nixos/org/remote-builder.nix sets it.
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
    local url=${O11N_REMOTE_BUILDER:?"set O11N_REMOTE_BUILDER to the builder's host"}
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

# Accommodating for gost, which logs nothing when the tunnel's requests fail: the endpoint is asked
# once, the same way, for a path under the prefix that the builder's gost doesn't serve, which
# answers 404.
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

store-info-command() {
    # Accommodating for Lix, forked before `nix store info`, which still calls it ping.
    if [[ $(nix --version) == *Lix* ]]; then echo ping; else echo info; fi
}

store-info() {
    start-tunnel
    nix store "$(store-info-command)" --store "unix://$socket" "$@"
}

# Policy: after a failure, a store that still answers through the tunnel means the build failed, not
# the tunnel.
store-answers() {
    timeout 60 nix store "$(store-info-command)" --store "unix://$socket" >/dev/null 2>&1
}

remote-build() {
    start-tunnel
    nix build --store "unix://$socket" --eval-store auto --no-link -L "$@"
}

eval-options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --dry-run | --rebuild | --print-out-paths | --no-link | --stdin) ;;
        -o | --out-link) shift ;;
        *) printf '%s\0' "$1" ;;
        esac
        shift
    done
}

# Accommodating for nix flake check --store, which asks the store which checks it would build
# before it has the derivations, and so builds none of them and passes: each is built instead.
remote-check() {
    local flake=. system
    if [[ -n ${1:-} && $1 != -* ]]; then
        flake=$1
        shift
    fi
    system=$(nix eval --raw --impure --expr builtins.currentSystem)

    local eval_options=() names checks=()
    mapfile -d '' -t eval_options < <(eval-options "$@")
    names=$(nix eval --json "$flake#checks.$system" --apply builtins.attrNames "${eval_options[@]}") ||
        die 1 "couldn't list the checks of $flake"
    mapfile -t checks < <(jq -r '.[]' <<<"$names")
    [[ ${#checks[@]} -gt 0 ]] || die 1 "$flake has no checks for $system"
    log info "checks: ${checks[*]}"

    remote-build "${checks[@]/#/$flake#checks.$system.}" "$@"
}

# Dependency: the host answers with nix's output, and a last line with its exit status.
remote-eval() {
    local stage=${1:-} o11n=${2:-} org server line status=
    [[ -n $stage && $# -le 2 ]] || die 1 "usage: nix-remote.sh eval <stage> [o11n revision]"
    [[ -z $o11n || $o11n =~ ^[0-9a-f]{40}$ ]] || die 1 "$o11n: give o11n's revision whole"
    command -v curl >/dev/null || die 1 "curl is not on PATH"
    org=$(git rev-parse HEAD)
    [[ -n $(git branch -r --contains "$org") ]] || die 1 "$org isn't pushed, and the host fetches it"

    server=${O11N_REMOTE_BUILDER:?"set O11N_REMOTE_BUILDER to the builder's host"}
    server=${server#*://}
    local args=(-sS -N --fail-with-body)
    if [[ -n ${O11N_REMOTE_BUILDER_TOKEN:-} ]]; then
        (umask 077 && echo "Authorization: Bearer $O11N_REMOTE_BUILDER_TOKEN" >"$tmpdir/headers")
        args+=(-H "@$tmpdir/headers")
    fi

    while IFS= read -r line; do
        if [[ $line =~ ^nix-remote-eval:\ exit\ ([0-9]+)$ ]]; then
            status=${BASH_REMATCH[1]}
        else
            printf '%s\n' "$line"
        fi
    done < <(curl "${args[@]}" "https://${server%%/*}/nix-eval/$stage/$org${o11n:+/$o11n}")
    [[ -n $status ]] || die 1 "the evaluation on ${server%%/*} didn't finish"
    return "$status"
}

nix-remote() {
    local cmd=${1:-}
    local rc=0
    shift || true

    if [[ $cmd == eval ]]; then
        remote-eval "$@" || rc=$?
        if [[ $rc -eq 0 ]]; then
            log success "evaluated and built on $O11N_REMOTE_BUILDER"
        fi
        return "$rc"
    fi

    case $cmd in
    info) store-info "$@" || rc=$? ;;
    build) remote-build "$@" || rc=$? ;;
    check) remote-check "$@" || rc=$? ;;
    *) die 1 "usage: nix-remote.sh info | build <installable>... | check [flake] | eval <stage> [o11n revision]" ;;
    esac

    if [[ $rc -ne 0 ]]; then
        if [[ $cmd != info ]] && store-answers; then
            log info "$O11N_REMOTE_BUILDER still answers, so the build failed and not the tunnel"
        else
            tail -n 20 "$tunnel_log" >&2
            diagnose
        fi
    elif [[ $cmd != info ]]; then
        log success "built on $O11N_REMOTE_BUILDER"
    fi
    return "$rc"
}

nix-remote "$@"
