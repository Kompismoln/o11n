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

    local address drv
    address=${BUILD_HOST_ADDRESS:-$(find-route.sh "$BUILD_HOST")}

    # Evaluated here, where the operator's own credentials fetch the org's private inputs.
    drv=$(nix eval --raw "$system.drvPath")

    # The build host builds as the untrusted nix-build and keeps the result, which
    # targets substitute from it.
    "$km_root/bin/as.sh" nix-build nix build \
        --eval-store auto \
        --store "ssh-ng://nix-build@$address" \
        "$drv^*" \
        --no-link \
        --print-out-paths \
        "$@"
}

build "$@"
