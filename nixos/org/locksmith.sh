#!/usr/bin/env bash
# nixos/org/locksmith.sh

set -euo pipefail

main() {
    case $1 in
    wg-key) ;;
    luks-key | age-key)
        IFS= read -r k1 || exit 1
        IFS= read -r k2 || k2=''
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
        decode "$k1" | cryptsetup luksRemoveKey "$dev" --key-file=-
    else
        decode "$k2" | cryptsetup luksAddKey "$dev" --key-file=<(decode "$k1") --new-keyfile=-
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
    decode "$k2" | tail -1 | age-keygen -y || exit 1

    decode "$k2" | tail -1 >>"$keyfile"

    if [[ "${2:-}" =~ ^[0-9]+$ ]] && (("$2" > 0)); then
        tail -"$2" "$keyfile" >"$keyfile.tmp" && mv "$keyfile.tmp" "$keyfile"
        exit 0
    fi
}

main "$@"
