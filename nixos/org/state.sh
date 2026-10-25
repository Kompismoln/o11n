#!/usr/bin/env bash
# nixos/org/state.sh

set -euo pipefail
mntdir=$(mktemp -d)

declare -x snapshot

mnt-cleanup() {
    fusermount -u "$mntdir"
    rmdir "$mntdir"
    kill "$mntpid"
}

state() {
    cmd=${1:?"command required"}
    cd "$HOME"

    [[ $cmd != "init" ]] || exec state-init

    file=${2:-"."}

    snapshot=${3:-"latest"}
    case $snapshot in
    0 | latest) : ;;
    '' | *[!0-9]*) : ;;
    *) : ;;
    esac

    case $cmd in
    status) state-status ;;
    commit) state-commit ;;
    restore) state-restore ;;
    diff) state-latest ;;
    check) state-check ;;
    snapshots) state-snapshots ;;
    *) echo "unknown command $1" >&2 ;;
    esac
}

state-init() {
    [[ -d .restic ]] || restic init
}

state-status() {
    local snapshot
    state-mount-snapshots
    fd . --ignore-file .resticignore --type f | while read -r file; do
        snapshot=$mntdir/snapshots/latest/$file

        if [[ ! -f $snapshot ]]; then
            echo "new file: $file"
            continue
        fi
        diff "$file" "$snapshot" &>/dev/null || echo "modified: $file"
    done

    fd . --base-directory "$mntdir/snapshots/latest" --type f | while read -r file; do
        if [[ ! -f $file ]]; then
            echo "deleted: $file"
        fi
    done
}

state-restore() {
    restic restore latest --target .
}

state-mount-snapshots() {
    trap mnt-cleanup EXIT
    restic mount "$mntdir" &>/dev/null &
    mntpid=$!
    local elapsed=0
    while ! mountpoint -q "$mntdir"; do
        if [ $elapsed -ge 100 ]; then
            echo "Timeout waiting for mount"
            exit 1
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
}

state-latest() {
    restic ls latest
}
state-snapshots() {
    restic snapshots
}
state-check() {
    restic backup . --dry-run --verbose=2 --exclude ".restic" --exclude-file ".resticignore"
}

state-commit() {
    restic backup . --exclude ".restic" --exclude-file ".resticignore"
}

state "$@"
