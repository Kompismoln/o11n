#!/usr/bin/env bash
# nixos/services/locksmith.sh

set -euo pipefail

main() {
    case $1 in
    wg-key) ;;
    luks-key | age-key)
        IFS= read -r k1 || exit 1
        IFS= read -r k2 || k2=''
        "$1"
        ;;
    initrd-key)
        IFS= read -r k1 || exit 1
        "$1"
        ;;
    *) exit 1 ;;
    esac
}

decode() {
    echo "$1" | base64 -d
}

luks-key() {
    local dev=$LUKS_DEVICE
    decode "$k1" | cryptsetup open "$dev" --key-file=- --test-passphrase || exit 1
    [[ -n $k2 ]] || exit 0
    if [[ "$k1" == "$k2" ]]; then
        local system key
        system=$(readlink -f "$SYSTEM_PROFILE")
        key=$(initrd-luks-key) || exit 1
        if [[ $key == "$k1" ]]; then
            echo "the initrd that boots $system holds this luks-key: deploy the one that replaces it first" >&2
            exit 1
        fi
        decode "$k1" | cryptsetup luksRemoveKey "$dev" --key-file=-
    else
        decode "$k2" | cryptsetup luksAddKey "$dev" --key-file=<(decode "$k1") --new-keyfile=-
    fi
}

# Dependency: nixpkgs' systemd-boot-builder.py appends the secrets to a copy of the system's initrd, which the entry
# that boots the system names, and install-grub.pl writes them to a file of their own.
initrd-secrets() {
    local system=$1 entry initrd
    case $BOOT_LOADER in
    systemd-boot)
        entry=$(grep -lF "init=$system/init " "$BOOT_DIR"/loader/entries/*.conf | head -1) || {
            echo "no boot entry boots $system" >&2
            exit 1
        }
        initrd=$(awk '$1 == "initrd" { print $2; exit }' "$entry")
        tail -c +$(($(stat -Lc %s "$system/initrd") + 1)) "$BOOT_DIR$initrd"
        ;;
    grub) cat "$BOOT_DIR/kernels/${system##*/}-secrets" ;;
    *)
        echo "no initrd secrets to read from boot loader '$BOOT_LOADER'" >&2
        exit 1
        ;;
    esac
}

# Policy: base64-encoded, as the lines locksmith reads.
initrd-luks-key() {
    local key
    key=$(initrd-secrets "$system" | bsdtar -xOf - "$INITRD_KEY_FILE" | base64 -w0) || exit 1
    if [[ -z $key ]]; then
        echo "the initrd that boots $system holds no luks-key" >&2
        exit 1
    fi
    echo "$key"
}

initrd-key() {
    local system key
    system=$(readlink -f "$SYSTEM_PROFILE")
    key=$(initrd-luks-key) || exit 1
    decode "$key" | cryptsetup open "$LUKS_DEVICE" --key-file=- --test-passphrase || {
        echo "the luks-key in the initrd that boots $system doesn't open $LUKS_DEVICE" >&2
        exit 1
    }
    if [[ -n $k1 && $key != "$k1" ]]; then
        echo "the luks-key in the initrd that boots $system opens $LUKS_DEVICE, but isn't the one a deployment writes" >&2
        exit 1
    fi
}

wg-key() {
    ping -c1 -I "$DEVICE" "$HOST"
}

age-key() {
    local keyfile=$KEY_FILE

    age-keygen -y <"$keyfile" | grep -qxF "$(decode "$k1" | age-keygen -y)" ||
        exit 1

    [[ -n $k2 ]] || exit 0
    if [[ "$k1" == "$k2" ]]; then
        sole-identity "$keyfile"
        exit 0
    fi
    decode "$k2" | tail -1 | age-keygen -y || exit 1

    decode "$k2" | tail -1 >>"$keyfile"
}

# Policy: the host keeps only the identity k1 holds once every sops file the system running and the one it boots next
# decrypt opens with it alone.
sole-identity() {
    local keyfile=$1 system file
    temp=$(mktemp -d)
    trap 'rm -rf "$temp"' EXIT
    (umask 077 && decode "$k1" | tail -1 >"$temp/identity")
    for system in "$(readlink -f "$CURRENT_SYSTEM")" "$(readlink -f "$SYSTEM_PROFILE")"; do
        if [[ ! -f $system/etc/o11n/sops-files ]]; then
            echo "$system doesn't list the sops files it decrypts: deploy before revoking" >&2
            exit 1
        fi
        while IFS= read -r file; do
            XDG_CONFIG_HOME=$temp SOPS_AGE_KEY_FILE=$temp/identity sops decrypt "$file" >/dev/null 2>&1 || {
                echo "$file, which $system decrypts, doesn't open with the current identity alone: deploy before revoking" >&2
                exit 1
            }
        done <"$system/etc/o11n/sops-files"
    done
    cp "$temp/identity" "$keyfile.tmp" && mv "$keyfile.tmp" "$keyfile"
}

main "$@"
