#!/usr/bin/env bash
# Usage: from an empty sample (no enc/, keys/ or public-keys/), with nix, o11n and sops on PATH,
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
for host in gw web; do
    o11n identity create "host-$host"
    o11n secret generate "host-$host" wg0-key
    # Fact: a host's ssh-key is its own, which `o11n host pull-ssh-key` would pull; here, one is made for it.
    rm -f "keys/host-$host-ssh-key"
    ssh-keygen -q -t ed25519 -N '' -C '' -f "keys/host-$host-ssh-key"
    cut -d' ' -f1-2 "keys/host-$host-ssh-key.pub" >"public-keys/host-$host-ssh-key.pub"
    rm "keys/host-$host-ssh-key" "keys/host-$host-ssh-key.pub"
done
o11n secret generate host-web luks-key

o11n identity create user-admin
for key in ssh-key passwd mail archive-passwd restic-key; do
    o11n secret generate user-admin "$key"
done

for service in rescue locksmith reverse-tunnel nix-build nix-switch nix-push egress-proxy; do
    o11n identity create "service-$service"
    o11n secret generate "service-$service" ssh-key
done

for service in archive dmarc-reports; do
    o11n identity create "service-$service"
    o11n secret generate "service-$service" mail
done

o11n secret generate service-rescue passwd
o11n secret hash service-rescue passwd >public-keys/service-rescue-passwd.sha512

o11n identity create service-nix-serve
o11n secret generate service-nix-serve nix-sign

o11n identity create service-domain-sample
o11n secret generate service-domain-sample tls-cert

o11n identity create service-nix-remote
o11n secret generate service-nix-remote secret-key
o11n secret generate service-nix-remote ssh-key
