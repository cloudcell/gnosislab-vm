#!/usr/bin/env bash
# sync-with-github.sh — reconcile the local default branch with the
# GitHub remote when `git pull` reports divergent branches.
#
#   behind only   -> fast-forward
#   diverged      -> rebase local commits onto the remote (linear
#                    history, which a PR-gated repo needs anyway)
#   ahead only    -> nothing to pull; report commits, optionally
#                    publish them as a branch + PR (--pr) since repo
#                    rules block direct pushes to the default branch
#
# Usage: scripts/sync-with-github.sh [--pr] [--branch <name>] [--dry-run]
# Env:   REMOTE   remote name (default origin)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

REMOTE=${REMOTE:-origin}
OPEN_PR=0 DRY_RUN=0 BRANCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pr)      OPEN_PR=1 ;;
        --branch)  BRANCH=${2:?'--branch needs a name'}; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "sync-with-github: unknown flag '$1'" >&2; exit 2 ;;
    esac
    shift
done

die()  { echo "sync-with-github: $*" >&2; exit 1; }
note() { echo "==> $*"; }

git remote get-url "$REMOTE" >/dev/null 2>&1 || die "no remote '$REMOTE'"
# remote default branch; fall back to master
DEF=$(git remote show "$REMOTE" 2>/dev/null | sed -n 's/^.*HEAD branch: //p')
DEF=${DEF:-master}
LOCAL=$(git branch --show-current)
[ -n "$LOCAL" ] || die "detached HEAD — check out a branch first"
[ "$LOCAL" = "$DEF" ] \
    || note "on '$LOCAL' — will sync it against $REMOTE/$DEF"
REF="$REMOTE/$DEF"

# tracked modifications block a merge/rebase; untracked files do not
[ -z "$(git status --porcelain | grep -v '^??')" ] \
    || die "uncommitted changes — commit or stash them first"

git fetch "$REMOTE" --tags --prune

counts() { git rev-list --left-right --count "$LOCAL...$REF"; }
read -r ahead behind <<<"$(counts)"

note "$LOCAL vs $REF: $ahead ahead / $behind behind"
if [ "$DRY_RUN" = 1 ]; then
    git log --oneline "$LOCAL..$REF" | sed 's/^/    remote: /'
    git log --oneline "$REF..$LOCAL" | sed 's/^/    local:  /'
    exit 0
fi

if [ "$behind" -gt 0 ]; then
    if [ "$ahead" -eq 0 ]; then
        note "fast-forwarding -> $REF ($behind commits)"
        git merge --ff-only "$REF"
    else
        note "diverged — rebasing $LOCAL onto $REF"
        if ! git rebase "$REF"; then
            echo "rebase stopped on a conflict." >&2
            echo "  resolve -> git add <files> -> git rebase --continue" >&2
            echo "  bail    -> git rebase --abort" >&2
            exit 1
        fi
    fi
    read -r ahead behind <<<"$(counts)"
fi

if [ "$ahead" -eq 0 ]; then
    note "up to date with $REF"
    exit 0
fi

note "$ahead local commit(s) not on $REF:"
git log --oneline "$REF..$LOCAL" | sed 's/^/    /'
if [ "$OPEN_PR" = 1 ]; then
    command -v gh >/dev/null || die "gh CLI required for --pr"
    BRANCH=${BRANCH:-sync-$(date -u +%Y%m%d-%H%M)Z}
    note "publishing as $REMOTE/$BRANCH and opening a PR"
    git branch -f "$BRANCH" "$LOCAL"
    git push -u "$REMOTE" "$BRANCH"
    gh pr create --fill --base "$DEF" --head "$BRANCH"
else
    echo "    pushes to $DEF are blocked by repo rules — publish via a PR:"
    echo "      git branch -f <name> $LOCAL && git push -u $REMOTE <name> && gh pr create"
    echo "    or rerun: $0 --pr"
fi
