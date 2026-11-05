#!/usr/bin/env bash

set -euo pipefail

setup-testenv() {
    local here root
    export TESTROOT=$BATS_TEST_TMPDIR/testroot

    here="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    root=$TESTROOT
    # Dependency: the ssh stub runs the other end of o11n's locksmith.
    export LOCKSMITH=$here/../../../nixos/services/locksmith.sh
    mkdir -p "$root"
    cp -a "$here/bin" "$here/org.toml" "$root"
    mkdir "$root/enc" "$root/keys" "$root/public-keys"
    export O11N_EXPORT
    O11N_EXPORT=$(test-export "$here")

    cd "$root" || exit 1

    export PATH="$root/bin:$PATH"
    export O11N_ROUTES="testhost=testhost.local"
}

# Optimization: the test org is evaluated once a run, unless the check that runs the tests has evaluated it.
test-export() {
    local export=${O11N_TEST_EXPORT:-$BATS_RUN_TMPDIR/org-export.json}
    [[ -s $export ]] || nix eval --json --no-warn-dirty --impure --expr "
        (builtins.getFlake \"git+file://$(cd "$1/../../.." && pwd)\").fromInventory { path = $1; }
    " --apply 'outputs: outputs.org.export' >"$export"
    echo "$export"
}

declare -g output status

succeeds() {
    ((status == 0)) || {
        echo "expected success, got $status: $output" >&2
        return 1
    }
}

fails() {
    ((status != 0)) && [[ $output == *"$1"* ]] || {
        echo "expected failure saying '$1', got $status: $output" >&2
        return 1
    }
}

mock-host() {
    local hostroot=$BATS_TEST_TMPDIR/host-$1.local
    mkdir -p "$hostroot/keys"

    echo "$test_age_key_1" >"$hostroot/keys/host-testhost"
    echo "$test_ssh_key_1" >"$hostroot/keys/ssh-key"
    chmod 600 "$hostroot/keys/ssh-key"
    echo "$test_luks_key_1" >"$hostroot/keys/luks-key"
}

# Dependency: nixos/services/locksmith.sh reads the sops files a system decrypts where nixos/services/locksmith.nix
# lists them.
mock-systems() {
    local hostroot=$BATS_TEST_TMPDIR/host-testhost.local system
    system=$hostroot/system-$RANDOM
    mkdir -p "$system/etc/o11n"
    printf '%s\n' "$@" >"$system/etc/o11n/sops-files"
    ln -sfn "$system" "$hostroot/system"
    ln -sfn "$system" "$hostroot/current"
}

# Dependency: nixos/services/locksmith.sh reads the initrd's secrets where nixpkgs' boot loaders write them.
mock-boot() {
    local loader=$1 key=$2 hostroot=$BATS_TEST_TMPDIR/host-testhost.local system secrets
    system=$hostroot/system-$RANDOM
    secrets=$BATS_TEST_TMPDIR/initrd-secrets
    rm -rf "${hostroot:?}/boot" "$secrets"
    mkdir -p "$system" "$secrets/.initrd-secrets" "$hostroot/boot/kernels" "$hostroot/boot/loader/entries" \
        "$hostroot/boot/EFI/nixos"
    system=$(readlink -f "$system")
    echo "the initrd of $system" >"$system/initrd"
    echo -n "$key" >"$secrets/.initrd-secrets/luks-key"
    ln -sfn "$system" "$hostroot/system"
    (cd "$secrets" && find . -mindepth 1 | bsdtar --format newc -cnzf - -T -) >"$secrets.cpio.gz"
    case $loader in
    grub) cp "$secrets.cpio.gz" "$hostroot/boot/kernels/${system##*/}-secrets" ;;
    systemd-boot)
        cat "$system/initrd" "$secrets.cpio.gz" >"$hostroot/boot/EFI/nixos/initrd.efi"
        printf 'linux /EFI/nixos/kernel.efi\ninitrd /EFI/nixos/initrd.efi\noptions init=%s/init loglevel=4\n' \
            "$system" >"$hostroot/boot/loader/entries/nixos.conf"
        ;;
    esac
    export BOOT_LOADER=$loader
}

test_age_key_1=AGE-SECRET-KEY-1L0EJY3FLSYHDE46Y80F0KLUKUWP6V3J340UR7G2GWNFGXJQ0P6ZQ6X37TN

test_ssh_key_1="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDEE3csx1IE4hhJQOzYQh7xZ8iZY6wj1C1xYp2DjxjmOAAAAKDYIpSm2CKU
pgAAAAtzc2gtZWQyNTUxOQAAACDEE3csx1IE4hhJQOzYQh7xZ8iZY6wj1C1xYp2DjxjmOA
AAAEA4YkpxaWCNi2sH27/j3HB+cMO81OHPrAzAeD15B1N9BcQTdyzHUgTiGElA7NhCHvFn
yJljrCPULXFinYOPGOY4AAAAF3Rlc3R1c2VyQHRlc3Rob3N0LmxvY2FsAQIDBAUG
-----END OPENSSH PRIVATE KEY-----"

test_luks_key_1="luks1-Atzc2gtZWQyNTUxO"
