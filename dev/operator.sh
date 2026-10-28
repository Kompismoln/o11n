#!/usr/bin/env bash
# Usage: ./dev/operator.sh fetch [branch] | stamp [message] | merge [branch] | check-org, in the dev
# shell, pulling and pushing through as.sh as $O11N_DEV.
set -euo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
cd "$(git rev-parse --show-toplevel)"

STAMPED=dev/stamped

as-dev() {
    as.sh "$O11N_DEV" "$@"
}

# Optimization: the commit stamp last found nothing pending in is held as stamped, so that stamp
# needn't look again while it is all there is.
stamped() {
    [[ -z $(git status --porcelain) && $(git rev-parse HEAD) == "$(cat "$STAMPED" 2>/dev/null)" ]]
}

fetch() {
    local branch=${1:-$(git branch --show-current)}
    as-dev git fetch --quiet origin
    git switch --quiet "$branch"
    git merge --ff-only --quiet "origin/$branch"
    ./check.sh pending || true
}

stamp() {
    if ! stamped; then
        ./check.sh pending >&2 || die "pending, as flagged above; nothing was committed"
        git add -A
        git diff --cached --quiet || git commit --quiet -m "${1:-stamp}"
        git rev-parse HEAD >"$STAMPED"
    fi
    [[ $(git rev-parse HEAD) == "$(git rev-parse --verify -q '@{u}')" ]] ||
        as-dev git push --quiet -u origin HEAD
    git rev-parse --short HEAD
}

merge() {
    local main=${MAIN:-main} branch=${1:-$(git branch --show-current)}
    local main_sha branch_sha here wt ref orig msgfile new
    [[ $branch != "$main" ]] || die "branch must differ from $main"
    [[ ! -d "$(git rev-parse --git-path rebase-merge)" && ! -d "$(git rev-parse --git-path rebase-apply)" ]] ||
        die "a rebase is in progress"

    if [[ -n $(git status --porcelain) ]]; then
        [[ $(git branch --show-current) == "$branch" ]] || die "uncommitted changes; commit or stash first"
        git add -A
        git commit --quiet -m merge
    fi

    main_sha=$(git rev-parse --verify -q "refs/heads/$main^{commit}") || die "no local branch '$main'"
    branch_sha=$(git rev-parse --verify -q "refs/heads/$branch^{commit}") || die "no local branch '$branch'"

    git merge-base --is-ancestor "$main_sha" "$branch_sha" ||
        die "'$branch' is not based on the tip of '$main' (rebase it onto $main first)"
    (($(git rev-list --count "$main_sha..$branch_sha") >= 1)) || die "'$branch' has no commits beyond '$main'"

    here=$(git rev-parse --show-toplevel)
    while read -r wt ref; do
        [[ $wt == "$here" ]] && continue
        [[ $ref == "refs/heads/$main" || $ref == "refs/heads/$branch" ]] &&
            die "'${ref#refs/heads/}' is checked out in worktree $wt"
    done < <(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{print w, $2}')

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
    git checkout -q "$branch"
    { pinned-on-main && ./check.sh pending eval >&2; } || {
        git checkout -q "$orig"
        die "'$branch' doesn't hold, for the above; nothing was merged"
    }

    msgfile=$tmp/message
    git log --reverse --format='%B' "$main_sha..$branch_sha" >"$msgfile"

    git checkout -q --detach "$branch_sha"
    git reset -q --soft "$main_sha"

    if ! git commit -e -F "$msgfile" >&2; then
        git reset -q --soft "$branch_sha"
        git checkout -q "$orig"
        die "commit aborted; nothing was changed"
    fi

    new=$(git rev-parse HEAD)
    [[ $(git rev-parse "$new^{tree}") == $(git rev-parse "$branch_sha^{tree}") ]] ||
        {
            git reset -q --soft "$branch_sha"
            git checkout -q "$orig"
            die "squash tree differs from '$branch' (hook modified files?); aborted"
        }

    git update-ref -m "squash-to-main: $branch" "refs/heads/$main" "$new" "$main_sha"
    git checkout -q "$main"
    as-dev git push --quiet origin "$main"
    git branch -q -D "$branch"
    if git rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null; then
        as-dev git push --quiet origin --delete "$branch"
    fi
    git rev-parse --short "$main"
}

# Policy: o11n squashes and deletes its branches like this, and their commits go with them, so a
# main pins o11n only to a commit on o11n's main.
pinned-on-main() {
    local url rev
    [[ -f flake.lock ]] || return 0
    read -r url rev < <(jq -r '.nodes.o11n.locked // empty
        | if .type == "github" then "https://github.com/\(.owner)/\(.repo) \(.rev)" else "\(.url) \(.rev)" end' flake.lock) ||
        return 0
    git init -q "$tmp/o11n"
    as-dev git -C "$tmp/o11n" fetch --quiet --filter=blob:none "$url" HEAD || return 1
    git -C "$tmp/o11n" merge-base --is-ancestor "$rev" FETCH_HEAD 2>/dev/null || {
        echo "'$branch' pins o11n at $rev, which isn't on o11n's main: merge o11n first and pin to its main" >&2
        return 1
    }
}

# check-org, with ORG set to an org's clone, relative to this one's root or not, builds the org's
# stages.eval with this clone's tree as its o11n.
check-org() {
    [[ -n ${ORG:-} ]] || die "ORG is unset, so there's no org to check"
    local here=$PWD
    cd "$ORG"
    nix build --no-link -L .#stages.eval --override-input o11n "git+file://$here"
}

case "${1:-}" in
fetch | stamp | merge)
    [[ -n ${O11N_DEV:-} ]] || die "O11N_DEV is unset, so as.sh has no one to pull and push as"
    command -v as.sh >/dev/null || die "no as.sh on PATH to pull and push with"
    "$1" "${2:-}"
    ;;
check-org) check-org ;;
*) die "usage: ./dev/operator.sh fetch [branch] | stamp [message] | merge [branch] | check-org" ;;
esac
