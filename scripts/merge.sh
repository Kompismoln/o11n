#!/usr/bin/env bash
# Usage: merge.sh [branch], the current one unless named, as O11N_DEV, with MAIN for another
# target than main. Squashes the branch's commits beyond main's tip into one on main, with the
# message git opens an editor for, switches to main and pushes it, deletes the branch here and
# on origin, and prints main's new revision; an empty message, or :cq in vim, changes nothing.
set -euo pipefail

main=${MAIN:-main}
branch=${1:-$(git branch --show-current)}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
cd "$(git rev-parse --show-toplevel)"
[[ -n ${O11N_DEV:-} ]] || die "O11N_DEV is unset, so as.sh has no one to push as"
command -v as.sh >/dev/null || die "no as.sh on PATH to push with"
[[ $branch != "$main" ]] || die "branch must differ from $main"

main_sha=$(git rev-parse --verify -q "refs/heads/$main^{commit}") || die "no local branch '$main'"
branch_sha=$(git rev-parse --verify -q "refs/heads/$branch^{commit}") || die "no local branch '$branch'"

git merge-base --is-ancestor "$main_sha" "$branch_sha" ||
    die "'$branch' is not based on the tip of '$main' (rebase it onto $main first)"

count=$(git rev-list --count "$main_sha..$branch_sha")
((count >= 1)) || die "'$branch' has no commits beyond '$main'"

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "uncommitted changes; commit or stash first"
fi
[[ ! -d "$(git rev-parse --git-path rebase-merge)" && ! -d "$(git rev-parse --git-path rebase-apply)" ]] ||
    die "a rebase is in progress"

here=$(git rev-parse --show-toplevel)
while read -r wt ref; do
    [[ $wt == "$here" ]] && continue
    [[ $ref == "refs/heads/$main" || $ref == "refs/heads/$branch" ]] &&
        die "'${ref#refs/heads/}' is checked out in worktree $wt"
done < <(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{print w, $2}')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Policy: o11n squashes and deletes its branches like this, and their commits go with them, so
# a main pins o11n only to a commit on o11n's main.
pinned-on-main() {
    local url rev
    [[ -f flake.lock ]] || return 0
    read -r url rev < <(jq -r '.nodes.o11n.locked // empty
        | if .type == "github" then "https://github.com/\(.owner)/\(.repo) \(.rev)" else "\(.url) \(.rev)" end' flake.lock) ||
        return 0
    git init -q "$tmp/o11n"
    as.sh "$O11N_DEV" git -C "$tmp/o11n" fetch --quiet --filter=blob:none "$url" HEAD || return 1
    git -C "$tmp/o11n" merge-base --is-ancestor "$rev" FETCH_HEAD 2>/dev/null || {
        echo "'$branch' pins o11n at $rev, which isn't on o11n's main: merge o11n first and pin to its main" >&2
        return 1
    }
}

holds() {
    pinned-on-main || return 1
    nix build --no-link -L .#stages.baseline >&2
}

orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
git checkout -q "$branch"
holds || {
    git checkout -q "$orig"
    die "'$branch' doesn't hold, for the above; nothing was changed"
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
as.sh "$O11N_DEV" git push --quiet origin "$main"
git branch -q -D "$branch"
if git rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null; then
    as.sh "$O11N_DEV" git push --quiet origin --delete "$branch"
fi
git rev-parse --short "$main"
