#!/usr/bin/env bash
# tools/bin/build.sh

set -euo pipefail

km_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$km_root/libexec/run-with.bash"

declare -x BUILD_HOST=${BUILD_HOST:-$(org-toml.sh build-hosts | head -n 1)}

build() {
    local target=$1
    shift
    local system=".#nixosConfigurations.$target.config.system.build.toplevel"

    if [[ $BUILD_HOST == localhost ]]; then
        nix build "$system" --no-link --print-out-paths "$@"
        return
    fi

    org-toml.sh build-hosts | grep -x "$BUILD_HOST" >/dev/null ||
        die 1 "$BUILD_HOST is not in build-hosts"

    [[ $# -eq 0 ]] || die 1 "nix options apply only with BUILD_HOST=localhost: $*"

    local address flake
    address=${BUILD_HOST_ADDRESS:-$(find-route.sh "$BUILD_HOST")}
    flake=$(nix flake metadata --json . | jq -r .path)

    # The build host evaluates the flake it is sent, inputs and all, so it needs no access
    # of its own to the private ones.
    "$km_root/bin/as.sh" nix-build nix flake archive --to "ssh-ng://nix-build@$address" .
    "$km_root/bin/as.sh" nix-build ssh "nix-build@$address" build-system "$flake" "$target"
}

build "$@"
