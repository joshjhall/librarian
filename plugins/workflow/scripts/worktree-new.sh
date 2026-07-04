#!/usr/bin/env bash
# worktree-new.sh — create a push-ready golem worktree for issue N (idempotent).
#
# Replaces the containers `worktree-new` just recipe so the golem/worktree
# flow runs WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Creates <GOLEM_WORKTREE_DIR>/issue-N on branch <GOLEM_BRANCH_PREFIX>N from
# <GOLEM_BASE_REF> and copies in the gitignored, machine-local files a push
# needs (GOLEM_WORKTREE_LOCAL_FILES — e.g. .env, .claude/settings.local.json).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR  (.worktrees)  GOLEM_BRANCH_PREFIX (feature/issue-)
#   GOLEM_BASE_REF      (origin/main) GOLEM_WORKTREE_LOCAL_FILES
#
# Usage: worktree-new.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "worktree-new: N must be an issue number, got '$N'" >&2
    exit 2
fi

root="$(repo_root)"
cd "$root"
wt="$GOLEM_WORKTREE_DIR/issue-$N"
br="${GOLEM_BRANCH_PREFIX}${N}"

if /usr/bin/git worktree list --porcelain | /usr/bin/grep -qx "worktree $root/$wt"; then
    command echo "worktree-new: $wt already exists — remove it first (worktree-rm.sh $N)" >&2
    exit 1
fi
if [ -n "$(/usr/bin/git branch --list "$br")" ]; then
    command echo "worktree-new: branch $br already exists — delete it or pick another issue" >&2
    exit 1
fi

# Fetch the base ref's remote (if any) so the worktree forks from up-to-date
# state. GOLEM_BASE_REF is typically "origin/main"; derive the remote + branch.
case "$GOLEM_BASE_REF" in
    */*)
        base_remote="${GOLEM_BASE_REF%%/*}"
        base_branch="${GOLEM_BASE_REF#*/}"
        /usr/bin/git fetch "$base_remote" "$base_branch" --quiet || true
        ;;
esac

/usr/bin/git worktree add "$wt" -b "$br" "$GOLEM_BASE_REF"

for f in $GOLEM_WORKTREE_LOCAL_FILES; do
    if [ -e "$f" ]; then
        /usr/bin/mkdir -p "$wt/$(/usr/bin/dirname "$f")"
        /usr/bin/cp "$f" "$wt/$f"
        command echo "  copied $f"
    else
        command echo "  skipped $f (not present in main checkout)"
    fi
done

# Seed a workspace-trust entry for the new worktree path so the copied
# settings.local.json (defaultMode "auto" + push/PR `ask` gates) actually
# loads — Claude Code does not load project settings for an UNTRUSTED folder,
# and a non-interactive tmux launch can't show the trust dialog. Complements
# the explicit `--permission-mode auto` in the launch hint below (which works
# even if this step is unavailable). Best-effort; always exits 0.
if [ -x "$SCRIPT_DIR/seed-worktree-trust.sh" ]; then
    "$SCRIPT_DIR/seed-worktree-trust.sh" "$root/$wt"
fi

command echo ""
command echo "Worktree ready: $wt (branch $br)"
command echo "Launch a golem there with:"
command echo "  tmux new-session -d -s golem-$N -c \"$root/$wt\" -e GOLEM_ID=golem-$N \"claude --permission-mode auto '/workflow:next-issue $N --level 4' ; claude --permission-mode auto '/workflow:ship-issue'\""
