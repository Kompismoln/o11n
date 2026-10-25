#!/usr/bin/env bash
# shellcheck disable=SC2029
# Yes, we know unescaped variables expand client side

set -euo pipefail

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

# How reset reaches a machine that isn't on the network, as tunnel sets them.
ssh_through=()
anywhere_through=()

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
        action=${2:?"tunnel open|close|status|connect|facts|reset required"}
        server="${3:?"tunnel server required"}.$domain"
        arg=${4:-}
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
    rm -rf "$tmpdir"
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

    if [[ -n ${server:-} ]]; then
        id-entities.sh -u admin cat-secret ssh-key | ssh-add - |& log info
    fi

    if ssh "${ssh_through[@]}" -o BatchMode=yes -o ConnectTimeout=5 "root@$address" true |& log error; then
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
        --copy-host-keys \
        "${anywhere_through[@]}"
}

# Both hops' keys in one agent: an as.sh nested in another's ProxyCommand would act as the outer
# one's identity, which can't read the other key.
stick_keys() {
    trap ssh_cleanup EXIT
    eval "$(ssh-agent -s)" > >(log info)
    id-entities.sh -u admin cat-secret ssh-key | ssh-add - |& log info
    id-entities.sh -s rescue cat-secret ssh-key | ssh-add - |& log info
}

stick() {
    ssh "${ssh_through[@]}" root@localhost "$@"
}

# The reverse tunnel on a server, for a machine booted from the rescue stick to call in through.
tunnel() {
    # As nixos/org/reverse-tunnel.nix forwards the stick.
    ssh_through=(-p 2603 -o "ProxyJump=admin@$server" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

    case $action in
    open)
        "$tools_root/bin/as.sh" admin ssh -t "admin@$server" sudo reverse-tunnel open ${arg:+"$(printf '%q' "$arg")"}
        ;;
    close | status)
        "$tools_root/bin/as.sh" admin ssh -t "admin@$server" sudo reverse-tunnel "$action"
        ;;
    connect)
        stick_keys
        stick
        ;;
    facts)
        host=${arg:?"tunnel facts needs the host it will be"}
        stick_keys
        mkdir -p "hosts/$host"
        stick nixos-facter >"hosts/$host/facter.json"
        git add --intent-to-add "hosts/$host/facter.json"
        log success "wrote hosts/$host/facter.json; its disks:"
        stick 'ls -l /dev/disk/by-id/ | grep -v -- -part'
        ;;
    reset)
        host=${arg:?"tunnel reset needs the host to install"}
        address=localhost
        # The machine builds its system from the caches over its own line, rather than receive it
        # through the server, and reboots only once it has the wifi it called in on.
        anywhere_through=(-p 2603 --ssh-option "ProxyJump=admin@$server" --build-on remote --phases "kexec,disko,install")

        # Needs the host's facter.json, as from tunnel facts.
        local nm
        nm=$(nix eval --raw ".#nixosConfigurations.$host.config" --apply '
            c: let p = c.o11n.preserve or { enable = false; };
            in (if p.enable then p.storage else "") + "/etc/NetworkManager"')

        reset
        ssh "${ssh_through[@]}" "root@$address" "
            if [ -d /etc/NetworkManager/system-connections ]; then
                mkdir -p /mnt$nm && cp -a /etc/NetworkManager/system-connections /mnt$nm/
            fi"
        ssh "${ssh_through[@]}" "root@$address" systemctl reboot || true
        log success "$host is rebooting into its new system"
        ;;
    *)
        die 1 "tunnel open|close|status|connect|facts|reset"
        ;;
    esac
}

main "$@"
