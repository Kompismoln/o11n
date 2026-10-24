#!/usr/bin/env bash
# shellcheck disable=SC2029
# Yes, we know unescaped variables expand client side

set -euo pipefail

km_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$km_root/libexec/run-with.bash"

main() {
    domain=$(org-toml.sh endpoint)

    case $1 in
    rebuild | login)
        host=$2
        user=${3:-admin}
        address=${4:-"$host.$domain"}
        ;;
    reset)
        host=$2
        user="root"
        address=${3:-"$host.$domain"}
        ;;
    tunnel)
        action=${2:?"tunnel open|close|status|connect required"}
        host="${3:?"tunnel host required"}.$domain"
        code=${4:-}
        ;;
    image)
        variant=${2:-iso-installer}
        ;;
    pull | push)
        user="admin"
        host=$2
        specifier="$user@$host.$domain"
        src=$3
        dest=${4:-"./"}
        ;;
    esac
    "$1"
}

image() {
    nixos-rebuild build-image --flake .#rescue-usb --image-variant "$variant"
}

pull() {
    with "$user"
    rsync -av --info=NAME,SKIP --partial --progress "$specifier":"$src" "$dest"
    chmod -R u+w "$dest"
    unwith
}

eff() {
    sudo cp "$1" "$tmpdir/asdf"
    sudo rm -f "$1"
    sudo mount --bind "$tmpdir/asdf" "$1"

    echo "Temporary $1 ($tmpdir/asdf) ready. Edit $1 freely."
}
push() {
    rsync -av --ignore-existing --info=NAME,SKIP --partial --progress "$src" "$user"@"$address":"$dest"
}

ssh_cleanup() {
    ssh-agent -k > >(log info)
}

reset() {
    trap ssh_cleanup EXIT
    local extra_files="$tmpdir/extra-files"
    local luks_key="$tmpdir/luks_key"
    local age_key="$extra_files/keys/host-$host"
    local rescue_ssh_key=$tmpdir/keys/rescue-ssh-key

    mkdir -p "$tmpdir/keys"

    install -d -m700 "$(dirname "$age_key")"

    id-entities.sh -h "$host" cat-secret luks-key >"$luks_key" || die 1 "no luks-key"
    id-entities.sh -h "$host" cat-secret age-key >"$age_key" || die 1 "no age-key"
    id-entities.sh -s rescue cat-secret ssh-key >"$rescue_ssh_key" || die 1 "no ssh-key for rescue"

    chmod 600 "$age_key"
    chmod 600 "$rescue_ssh_key"

    eval "$(ssh-agent -s)" > >(log info)
    ssh-add "$rescue_ssh_key" |& log info

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$address" true |& log error; then
        log success "SSH connection to root@$address successful"
    else
        die 1 "SSH to root@$address connection failed"
    fi

    nixos-anywhere \
        -i "$rescue_ssh_key" \
        --flake ".#$host" \
        --target-host "root@$address" \
        --ssh-option GlobalKnownHostsFile=/dev/null \
        --disk-encryption-keys "/keys/host-$host" "$age_key" \
        --disk-encryption-keys "/luks-key" "$luks_key" \
        --generate-hardware-config nixos-facter hosts/"$host"/facter.json \
        --extra-files "$extra_files" \
        --copy-host-keys
}

# The reverse tunnel on a server, for a machine booted from the rescue stick to call in through.
tunnel() {
    case $action in
    open)
        "$km_root/bin/as.sh" admin ssh -t "admin@$host" sudo reverse-tunnel open ${code:+"$(printf '%q' "$code")"}
        ;;
    close | status)
        "$km_root/bin/as.sh" admin ssh -t "admin@$host" sudo reverse-tunnel "$action"
        ;;
    connect)
        # As nixos/org/reverse-tunnel.nix forwards it.
        "$km_root/bin/as.sh" rescue ssh \
            -o ProxyCommand="$km_root/bin/as.sh admin ssh -W %h:%p admin@$host" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -p 2603 root@localhost
        ;;
    *)
        die 1 "tunnel open|close|status|connect"
        ;;
    esac
}

main "$@"
