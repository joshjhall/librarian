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
# Belt-and-suspenders: after teardown it repairs a polluted main-repo
# `core.worktree` (#258). An interrupted `git worktree remove --force` can leave
# the MAIN checkout's .git/config with a stale `core.worktree` pointing at the
# just-removed worktree, which silently breaks it — `git status` shows the whole
# tree as deleted and `git rev-parse --is-inside-work-tree` returns false. No
# script legitimately sets `core.worktree` on the main config, so one pointing at
# a non-existent path is unambiguous corruption and is safe to unset.
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

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# Scrub git's hook-exported environment process-wide (#328). repo_root()
# (config.sh) already scrubs its OWN rev-parse subshell (#279), but this script
# then runs its own git MUTATIONS below (worktree remove / branch -D /
# config --unset core.worktree / worktree prune); a tainted GIT_DIR/GIT_COMMON_DIR
# forwarded from a git hook would redirect those to an OUTER repo — deleting a
# branch or unsetting core.worktree in the wrong checkout. `cd "$root"` does not
# re-anchor git while GIT_DIR is set, so unset the whole set here, before
# repo_root() and every other git call. Deliberately NO `|| true`: a readonly
# GIT_DIR makes `unset` fail, which under `set -e` aborts LOUDLY before any
# mutation — the fail-loud outcome, never a silent wrong-repo write. Uses
# config.sh's shared _git_env_scrub_names (#356 / #355) so the scrub set — static
# vars PLUS the dynamic GIT_CONFIG_KEY_<n>/VALUE_<n> pairs — stays in lockstep
# with repo_root()'s and worktree-new.sh's, one source of truth.
# shellcheck disable=SC2046  # intentional word-split: unset each scrub var by name
unset $(_git_env_scrub_names)

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

if command git worktree list --porcelain | command grep -qx "worktree $root/$wt"; then
    if command git worktree remove "$wt" 2>/dev/null; then
        command echo "  removed worktree $wt"
        removed=1
    else
        # Plain `git worktree remove` refuses a worktree that contains a
        # POPULATED submodule ("working trees containing submodules cannot be
        # moved or removed") even when the submodule is clean — and
        # worktree-new.sh now populates submodules on creation (#325), so this
        # now fires on ORDINARY teardown, not just on genuine uncommitted work.
        # Distinguish the two before forcing: `status --ignore-submodules=all`
        # reports only NON-submodule changes, so an EMPTY result means the
        # submodule presence is the sole blocker → safe to force-remove; a
        # NON-EMPTY result is real uncommitted regular-file work → refuse as
        # before. This gate is load-bearing: when a worktree has BOTH a dirty
        # regular file AND a populated submodule, git prints the submodule
        # message, so a bare `--force` would SILENTLY discard the user's changes
        # (verified) — the ignore-submodules status is what tells them apart.
        dirty="$(command git -C "$wt" status --porcelain --ignore-submodules=all 2>/dev/null || true)"
        if [ -z "$dirty" ] && command git worktree remove --force "$wt" 2>/dev/null; then
            command echo "  removed worktree $wt (forced past clean submodules)"
            removed=1
        else
            command echo "worktree-rm: $wt has uncommitted changes." >&2
            command echo "  Re-run after committing, or force: git worktree remove --force $wt" >&2
            exit 1
        fi
    fi
fi

if [ -n "$(command git branch --list "$br")" ]; then
    command git branch -D "$br"
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

# Repair a polluted main-repo core.worktree (#258). An interrupted
# `git worktree remove --force` can leave the MAIN config with a stale
# core.worktree pointing at a now-deleted path, which makes the whole checkout
# look deleted (git status = all D, rev-parse --is-inside-work-tree = false).
# Only unset it when it points at a path that no longer exists — a legit,
# existing core.worktree is left untouched. `cd "$root"` above put us in the main
# checkout, so `git config` reads/writes the main config.
stale_wt="$(command git config --get core.worktree 2>/dev/null || true)"
if [ -n "$stale_wt" ] && [ ! -e "$stale_wt" ]; then
    command git config --unset core.worktree || true
    command git worktree prune || true
    command echo "  repaired stale core.worktree ($stale_wt no longer exists)"
    removed=1
    if [ "$(command git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
        command echo "worktree-rm: WARNING: main checkout still not a work tree after core.worktree repair" >&2
    fi
fi

# Emit a terminal `reaped` feed event so a golem torn down here does not linger
# on golem-status.sh's BLOCKED list (#446). Teardown otherwise leaves the golem's
# last `gate` line as its most-recent feed entry, so the reader keeps rendering
# it BLOCKED for the whole GOLEM_BLOCK_TTL window even though its PR merged and
# its session is gone (the `golem-743` ghost in the issue). A `REAPED:`-prefixed
# Notification classifies as the `reaped` kind, which — like `idle`/`resolved` —
# is NOT in the BLOCKED set, so as the golem's most-recent line it supersedes the
# stale gate on the next sweep. Only when something was actually removed
# (`removed=1`): a no-op teardown had no live golem to reap.
#
# GOLEM_ID=golem-$N is forced for the same reason golem-resolve.sh forces it:
# this script runs in the MAIN checkout (`cd "$root"` above), so the hook's
# git-worktree-basename fallback would resolve to the main repo and stamp
# `golem-?`, never correlating to the reaped golem. Best-effort and never fails
# teardown — the hook always exits 0, and `|| true` keeps `set -e` from aborting
# over a missing hook / absent jq.
if [ "$removed" -eq 1 ]; then
    notify_hook="$SCRIPT_DIR/../hooks/golem-notify.sh"
    if [ -x "$notify_hook" ]; then
        msg="REAPED: worktree/session for golem-$N torn down"
        if command -v jq >/dev/null 2>&1; then
            reaped_payload="$(jq -cn --arg m "$msg" '{message: $m}')"
        else
            reaped_payload="$(command printf '{"message":"%s"}' "$msg")"
        fi
        command printf '%s' "$reaped_payload" | GOLEM_ID="golem-$N" "$notify_hook" || true
    fi
fi

if [ "$removed" -eq 0 ]; then
    command echo "worktree-rm: nothing to remove for issue $N ($wt / $br / $sess absent)"
fi
