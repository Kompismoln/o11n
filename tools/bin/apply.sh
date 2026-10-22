#!/usr/bin/env bash
# tools/bin/apply.sh

set -euo pipefail

km_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$km_root/libexec/run-with.bash"

declare -x target=${1:?target required}
declare -x \
    BUILD_HOST=${BUILD_HOST:-$(org-toml.sh build-hosts | head -n 1)} \
    TARGET_ADDRESS=${TARGET_ADDRESS:-$(find-route.sh "$target")}

apply() {
    log info "use $BUILD_HOST to build $target (at $TARGET_ADDRESS)"

    with build
    log important "build=$build"

    # From a build host, the target substitutes the build when it switches.
    if [[ $BUILD_HOST == localhost && $TARGET_ADDRESS != localhost ]]; then
        "$km_root/bin/as.sh" nix-push nix copy --to "ssh://nix-push@$TARGET_ADDRESS" "$build"
    fi

    log important "switching $target to $build"
    "$km_root/bin/as.sh" nix-switch ssh "nix-switch@$TARGET_ADDRESS" "$build"
}

declare -g build
build() {
    "$km_root/bin/build.sh" "$target"
}

apply
