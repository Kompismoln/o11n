#!/usr/bin/env bash
# tools/bin/build.sh

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"
org-exported

declare -x BUILD_HOST=${BUILD_HOST:-$(o11n get build-hosts | head -n 1)}

build() {
    local target=$1
    shift
    local system=".#nixosConfigurations.$target.config.system.build.toplevel"

    if [[ $BUILD_HOST == localhost ]]; then
        nix build "$system" --no-link --print-out-paths "$@"
        return
    fi

    o11n get build-hosts | grep -x "$BUILD_HOST" >/dev/null ||
        die 1 "$BUILD_HOST is not in build-hosts"

    [[ $# -eq 0 ]] || die 1 "nix options apply only with BUILD_HOST=localhost: $*"

    local address flake
    address=${BUILD_HOST_ADDRESS:-$(find-route.sh "$BUILD_HOST")}
    flake=$(nix flake metadata --json . | jq -r .path)

    # The build host evaluates the flake it is sent, inputs and all, so it needs no access
    # of its own to the private ones.
    "$tools_root/bin/as.sh" nix-build nix flake archive --to "ssh-ng://nix-build@$address" .
    local out
    out=$("$tools_root/bin/as.sh" nix-build ssh -n "nix-build@$address" build-system "$flake" "$target") ||
        die $? "$BUILD_HOST couldn't build $target"

    # Where nix-build has the daemon alone, the daemon gets no client and answers nothing.
    [[ $out == /nix/store/* ]] || die 1 "$BUILD_HOST has no build-system: on a configuration from
before it, nix-build reaches the daemon alone. Deploy it once with:
    BUILD_HOST=localhost apply.sh $BUILD_HOST"
    echo "$out"
}

build "$@"
