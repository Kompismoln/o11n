#!/bin/bash
# .claude/hooks/session-start.sh
#
# Claude Code cloud sessions can't download GitHub archives (HTTP 403), and
# that is how Nix fetches github: flake inputs; git over https works. This
# fetches every github: input in flake.lock over git, at the locked revision,
# so it is in the store under the content hash the lock expects and plain nix
# commands work. Inputs it can't reach, like private git+ssh ones, are left out.
#
# It also puts the formatters, linters and the tools' dependencies on PATH, and
# unshallows the clone so it can be read as git+file://.

set -euo pipefail

[[ ${CLAUDE_CODE_REMOTE:-} == true ]] || exit 0
cd "$CLAUDE_PROJECT_DIR"

# nixpkgs as this repo pins it
nixpkgs=".#nixpkgs.legacyPackages.x86_64-linux"
nixpkgs_args=()

packages=(nixfmt statix deadnix shellcheck bats age sops jq toml2json wireguard-tools openssh openssl mkpasswd gettext)

roots=/nix/var/nix/gcroots/claude-session
rm -rf "$roots"
mkdir -p "$roots"

log() { echo "session-start: $*" >&2; }

if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
    git fetch --quiet --unshallow || log "could not unshallow the clone"
fi

mapfile -t refs < <(
    python3 - flake.lock <<'EOF'
import json, sys
for node in json.load(open(sys.argv[1]))["nodes"].values():
    locked = node.get("locked", {})
    if locked.get("type") == "github":
        print(f"git+https://github.com/{locked['owner']}/{locked['repo']}?rev={locked['rev']}&shallow=1")
EOF
)

fetch_log=$(mktemp)
trap 'rm -f "$fetch_log"' EXIT

i=0
for ref in $(printf '%s\n' "${refs[@]}" | sort -u); do
    if path=$(nix flake prefetch --json "$ref" 2>"$fetch_log" | python3 -c 'import json, sys; print(json.load(sys.stdin)["storePath"])'); then
        nix-store --quiet --add-root "$roots/input-$((i++))" --realise "$path" >/dev/null
    else
        log "could not fetch $ref:"
        cat "$fetch_log" >&2
    fi
done

bins=()
for out in $(nix build --no-link --print-out-paths "${nixpkgs_args[@]}" "${packages[@]/#/$nixpkgs.}" .#gost); do
    nix-store --quiet --add-root "$roots/tool-$((i++))" --realise "$out" >/dev/null
    if [[ -d $out/bin ]]; then bins+=("$out/bin"); fi
done

if [[ -n ${CLAUDE_ENV_FILE:-} && ${#bins[@]} -gt 0 ]]; then
    echo "export PATH=\"$(IFS=:; echo "${bins[*]}"):\$PATH\"" >>"$CLAUDE_ENV_FILE"
fi
