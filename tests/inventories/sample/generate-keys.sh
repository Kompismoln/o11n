#!/usr/bin/env bash
# Creates the sample's identities and secrets from scratch with id-entities.sh,
# the same way an org creates its own. keys/root-1 is committed on purpose: it is
# a throwaway root identity that protects nothing but this inventory's secrets.
#
# Run from an empty sample (no enc/, keys/ or public-keys/) with age, jq, mkpasswd,
# nix, openssl, sops, ssh-keygen, toml2json, wg and envsubst on PATH.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
PATH="$(cd ../../../tools/bin && pwd):$PATH"
export SOPS_AGE_KEY_FILE=$PWD/keys/root-1

mkdir -p enc keys public-keys

id-entities.sh -r 1 init

# hosts first, so they can be recipients of the entities granted to them
for host in gw web; do
    id-entities.sh -h "$host" init
    id-entities.sh -h "$host" new wg0-key
done

# A host's ssh-key is pulled from the live host, which the sample has none of.
tmp=$(mktemp -d)
for host in gw web; do
    ssh-keygen -q -t ed25519 -N "" -C "host-$host" -f "$tmp/$host"
    sops set "enc/host-$host.yaml" '["ssh-key"]' "$(jq -Rs . <"$tmp/$host")"
    ssh-keygen -y -C "" -f "$tmp/$host" >"public-keys/host-$host-ssh-key.pub"
done
rm -r "$tmp"

id-entities.sh -u admin init
for key in ssh-key passwd mail; do
    id-entities.sh -u admin new "$key"
done

for service in rescue locksmith reverse-tunnel nix-build nix-switch nix-push egress-proxy; do
    id-entities.sh -s "$service" init
    id-entities.sh -s "$service" new ssh-key
done

id-entities.sh -s rescue new passwd
id-entities.sh -s rescue sha512-secret passwd >public-keys/service-rescue-passwd.sha512

id-entities.sh -s nix-serve init
id-entities.sh -s nix-serve new nix-sign

id-entities.sh -s nix-remote init
id-entities.sh -s nix-remote new secret-key
id-entities.sh -s nix-remote new ssh-key
