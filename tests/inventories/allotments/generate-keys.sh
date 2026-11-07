#!/usr/bin/env bash
# Usage: from an empty inventory (no enc/, keys/ or public-keys/), with nix, o11n and sops on PATH,
# creates what its hosts' systems read. keys/root-1 is committed on purpose: a throwaway root
# identity that protects nothing but this inventory's secrets.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
export SOPS_AGE_KEY_FILE=$PWD/keys/root-1

# Accommodating for an inventory, which is no flake: the tools read its export from a file.
export O11N_EXPORT O11N_ORG_ROOT=$PWD
O11N_EXPORT=$(mktemp)
trap 'rm -f "$O11N_EXPORT"' EXIT
nix eval --json --impure --expr "(builtins.getFlake \"git+file://$(cd ../../.. && pwd)\").fromInventory { path = $PWD; }" \
    --apply 'outputs: outputs.org.export' >"$O11N_EXPORT"

mkdir -p enc keys public-keys

o11n identity create root-1
for host in zhost laptop; do
    o11n identity create "host-$host"
    o11n secret generate "host-$host" wg0-key
    o11n secret generate "host-$host" syncthing-user-alice.zhost
done
o11n secret generate host-zhost luks-key
o11n identity create app-cloud
o11n secret generate app-cloud ssh-key
o11n secret generate app-cloud sftp-key
