#!/usr/bin/env bash
# worktree-rm.sh — post-merge cleanup: remove the issue-N worktree and its
# branch (clean no-op if absent).
#
# Replaces the containers `worktree-rm` just recipe so the golem/worktree flow
# runs WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Removes <GOLEM_WORKTREE_DIR>/issue-N, deletes branch <GOLEM_BRANCH_PREFIX>N,
# and kills the golem's tmux session golem-N (idempotent — ignore-if-absent),
# so worktree teardown and session teardown are ONE step and finished golems
# don't linger in `tmux ls` / golem-status.sh after a merge+prune (#27).
# Refuses to remove a worktree with uncommitted changes (re-run after
# committing, or force with `git worktree remove --force`).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
#
# NOTE: the containers recipe also refreshed a bare host's on-disk runtime
# copies (.claude/hooks, justfile, bin) from origin/main after teardown — that
# was specific to the containers repo's bare-host golem layout and its
# bin/sync-host.sh, so it is intentionally NOT carried into this portable
# script.
#
# Usage: worktree-rm.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "worktree-rm: N must be an issue number, got '$N'" >&2
    exit 2
fi

root="$(repo_root)"
cd "$root"
wt="$GOLEM_WORKTREE_DIR/issue-$N"
br="${GOLEM_BRANCH_PREFIX}${N}"
removed=0

if /usr/bin/git worktree list --porcelain | /usr/bin/grep -qx "worktree $root/$wt"; then
    if ! /usr/bin/git worktree remove "$wt" 2>/dev/null; then
        command echo "worktree-rm: $wt has uncommitted changes." >&2
        command echo "  Re-run after committing, or force: git worktree remove --force $wt" >&2
        exit 1
    fi
    command echo "  removed worktree $wt"
    removed=1
fi

if [ -n "$(/usr/bin/git branch --list "$br")" ]; then
    /usr/bin/git branch -D "$br"
    command echo "  deleted branch $br"
    removed=1
fi

# Kill the golem's tmux session so a finished golem does not linger in
# `tmux ls` / golem-status.sh after merge+prune (#27). Idempotent and
# ignore-if-absent: a missing session (or no tmux at all) is a clean no-op, and
# the `|| true` keeps `set -e` from aborting teardown over it.
sess="golem-$N"
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$sess" 2>/dev/null; then
    tmux kill-session -t "$sess" 2>/dev/null || true
    command echo "  killed tmux session $sess"
    removed=1
fi

if [ "$removed" -eq 0 ]; then
    command echo "worktree-rm: nothing to remove for issue $N ($wt / $br / $sess absent)"
fi
