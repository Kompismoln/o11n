#!/usr/bin/env bash
# tools/remote/nixservice.sh
set -euo pipefail

declare -x SOURCE=${SOURCE:-${REPO:-}}

main() {
    local cmd=$1
    shift
    local nix_args=()
    local script_args=()

    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift
            nix_args=("$@")
            break
        else
            script_args+=("$1")
            shift
        fi
    done
    case $cmd in

    build)
        local host=${script_args[0]:?"host required"}
        local source=${script_args[1]:-${SOURCE:?"source required"}}
        rm -rf "$HOME/.cache/nix/"*
        nix build "$source#nixosConfigurations.$host.config.system.build.toplevel" \
            --no-link \
            --print-out-paths \
            "${nix_args[@]}"
        ;;
    pull)
        local closure=${script_args[0]:?"closure required"}
        local build_host=${script_args[1]:?"build host required"}
        nix copy --from "$build_host" "$closure" "${nix_args[@]}"
        ;;
    switch)
        local generation=${script_args[0]:-}
        if [[ $generation =~ ^/nix/store/ ]]; then
            nix-env -p /nix/var/nix/profiles/system --set "$generation"
        elif [[ -n "$generation" ]]; then
            nix-env -p /nix/var/nix/profiles/system --switch-generation "$generation"
        fi

        nix-env -p /nix/var/nix/profiles/system --list-generations

        if [[ -n "$generation" ]]; then
            /nix/var/nix/profiles/system/bin/switch-to-configuration switch
        fi
        ;;
    *) exit 1 ;;
    esac
}

main "$@"
