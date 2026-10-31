#!/usr/bin/env bash
# Creates the sample's identities and secrets from scratch with o11n,
# the same way an org creates its own. keys/root-1 is committed on purpose: it is
# a throwaway root identity that protects nothing but this inventory's secrets.
#
# Run from an empty sample (no enc/, keys/ or public-keys/) with nix, o11n and sops on PATH.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
PATH="$(cd ../../../tools/bin && pwd):$PATH"
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
for host in gw web; do
    o11n identity create "host-$host"
    o11n secret generate "host-$host" wg0-key
    o11n secret generate "host-$host" ssh-key
done

o11n identity create user-admin
for key in ssh-key passwd mail; do
    o11n secret generate user-admin "$key"
done

for service in rescue locksmith reverse-tunnel nix-build nix-switch nix-push egress-proxy; do
    o11n identity create "service-$service"
    o11n secret generate "service-$service" ssh-key
done

o11n secret generate service-rescue passwd
o11n secret hash service-rescue passwd >public-keys/service-rescue-passwd.sha512

o11n identity create service-nix-serve
o11n secret generate service-nix-serve nix-sign

o11n identity create service-nix-remote
o11n secret generate service-nix-remote secret-key
o11n secret generate service-nix-remote ssh-key
