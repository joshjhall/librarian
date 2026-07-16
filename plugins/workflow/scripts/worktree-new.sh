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

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if command git worktree list --porcelain | command grep -qx "worktree $root/$wt"; then
    command echo "worktree-new: $wt already exists — remove it first (worktree-rm.sh $N)" >&2
    exit 1
fi
if [ -n "$(command git branch --list "$br")" ]; then
    command echo "worktree-new: branch $br already exists — delete it or pick another issue" >&2
    exit 1
fi

# Fetch the base ref's remote (if any) so the worktree forks from up-to-date
# state. GOLEM_BASE_REF is typically "origin/main"; derive the remote + branch.
case "$GOLEM_BASE_REF" in
    */*)
        base_remote="${GOLEM_BASE_REF%%/*}"
        base_branch="${GOLEM_BASE_REF#*/}"
        command git fetch "$base_remote" "$base_branch" --quiet || true
        ;;
esac

command git worktree add "$wt" -b "$br" "$GOLEM_BASE_REF"

# Populate submodules the worktree's checkout references (e.g. a `containers`
# submodule whose bin/fix-*.sh the root lefthook pre-commit hook calls). Plain
# `git worktree add` never populates submodules, so in a consuming repo where a
# submodule ships the pre-commit fixers, every commit in the worktree fails the
# hook non-deterministically depending on the submodule's checkout state at
# `worktree add` time (issue #325, migrated from containers#638). `--init
# --recursive` respects each submodule's `.gitmodules` `update = none` pin (it
# prints "Skipping submodule"), so librarian's own pinned `containers` submodule
# is a no-op here while a live submodule in a consuming repo gets populated; a
# repo with no submodules is a clean no-op. Best-effort with a LOUD warning: a
# populate failure (offline/auth) must not abort an otherwise-good worktree, but
# it must never be silent — the silent missing-hook-script mystery (a golem spent
# ~20 min on it) is exactly the bug this fixes.
# GIT_TERMINAL_PROMPT=0 so a submodule with an HTTPS remote and no cached
# credentials fails fast instead of hanging on an interactive username/password
# prompt — an indefinite hang would defeat the best-effort intent (this can be
# run from a real terminal, not only a headless golem). Mirrors the fail-fast
# posture of golem-launch.sh's bounded auth read.
if ! GIT_TERMINAL_PROMPT=0 command git -C "$wt" submodule update --init --recursive; then
    command echo "worktree-new: WARNING — submodule init failed in $wt;" \
        "pre-commit hooks that call submodule scripts may fail there" >&2
fi

for f in $GOLEM_WORKTREE_LOCAL_FILES; do
    if [ -e "$f" ]; then
        command mkdir -p "$wt/$(command dirname "$f")"
        command cp "$f" "$wt/$f"
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
