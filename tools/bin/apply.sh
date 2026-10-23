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
    local rc=0
    "$km_root/bin/as.sh" nix-switch ssh "nix-switch@$TARGET_ADDRESS" "$build" 2>&1 |
        tee "$tmpdir/switch.log" || rc=$?

    # Nix's words for a path that no substituter has.
    if ((rc != 0)) && [[ $BUILD_HOST != localhost ]] &&
        grep -q "don't know how to build these paths" "$tmpdir/switch.log"; then
        die "$rc" "$target couldn't fetch the build from $BUILD_HOST. To copy it there instead:
    BUILD_HOST=localhost apply.sh $target
$target fetches from the hosts with the substituter role in the configuration it runs
now: check that its /etc/nix/nix.conf lists $BUILD_HOST among the substituters, and
that it reaches $BUILD_HOST on port 5000."
    fi
    return "$rc"
}

declare -g build
build() {
    "$km_root/bin/build.sh" "$target"
}

apply
