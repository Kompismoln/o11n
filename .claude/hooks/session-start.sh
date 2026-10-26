#!/bin/bash
# .claude/hooks/session-start.sh
#
# Claude Code cloud sessions can't download GitHub archives (HTTP 403), and
# that is how Nix fetches github: flake inputs; git over https works. This
# fetches every github: input in flake.lock over git with
# dev/fetch-github-inputs.sh, so plain nix commands work, and roots them.
#
# It also puts the formatters, linters and the tools' dependencies on PATH, and
# unshallows the clone so it can be read as git+file://.

set -euo pipefail

[[ ${CLAUDE_CODE_REMOTE:-} == true ]] || exit 0
cd "$CLAUDE_PROJECT_DIR"

# nixpkgs as this repo pins it
nixpkgs=".#nixpkgs.legacyPackages.x86_64-linux"
nixpkgs_args=()

packages=(nixfmt statix deadnix shellcheck bats age sops jq toml2json wireguard-tools openssh openssl mkpasswd gettext tree util-linux)

roots=/nix/var/nix/gcroots/claude-session
rm -rf "$roots"
mkdir -p "$roots"

log() { echo "session-start: $*" >&2; }

if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
    git fetch --quiet --unshallow || log "could not unshallow the clone"
fi

i=0
while IFS= read -r path; do
    nix-store --quiet --add-root "$roots/input-$((i++))" --realise "$path" >/dev/null
done < <(dev/fetch-github-inputs.sh)

bins=()
for out in $(nix build --no-link --print-out-paths "${nixpkgs_args[@]}" "${packages[@]/#/$nixpkgs.}" .#gost); do
    nix-store --quiet --add-root "$roots/tool-$((i++))" --realise "$out" >/dev/null
    if [[ -d $out/bin ]]; then bins+=("$out/bin"); fi
done

if [[ -n ${CLAUDE_ENV_FILE:-} && ${#bins[@]} -gt 0 ]]; then
    echo "export PATH=\"$(IFS=:; echo "${bins[*]}"):\$PATH\"" >>"$CLAUDE_ENV_FILE"
fi
