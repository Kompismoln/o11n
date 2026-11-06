#!/usr/bin/env bash
# Usage: from an empty inventory (no enc/, keys/ or public-keys/), with nix, o11n and sops on PATH,
# creates its identities and secrets as an org creates its own. keys/root-1 is committed on
# purpose: a throwaway root identity that protects nothing but this inventory's secrets.

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

# Dependency: hosts first, as what's granted to them is encrypted to them.
for host in mx web; do
    o11n identity create "host-$host"
    o11n secret generate "host-$host" wg0-key
    # Fact: a host's ssh-key is its own, which `o11n host pull-ssh-key` would pull; here, one is made for it.
    rm -f "keys/host-$host-ssh-key"
    ssh-keygen -q -t ed25519 -N '' -C '' -f "keys/host-$host-ssh-key"
    cut -d' ' -f1-2 "keys/host-$host-ssh-key.pub" >"public-keys/host-$host-ssh-key.pub"
    rm "keys/host-$host-ssh-key" "keys/host-$host-ssh-key.pub"
done

o11n identity create user-alice
for key in ssh-key passwd mail; do
    o11n secret generate user-alice "$key"
done

for app in blog calendar; do
    o11n identity create "app-$app"
    o11n secret generate "app-$app" ssh-key
    o11n secret generate "app-$app" mail
done

o11n identity create app-auth
for key in ssh-key mail admin-client-secret; do
    o11n secret generate app-auth "$key"
done

o11n identity create app-cloud
for key in ssh-key secret-key oidc-secret; do
    o11n secret generate app-cloud "$key"
done
