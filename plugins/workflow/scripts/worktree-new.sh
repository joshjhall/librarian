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

# Scrub git's hook-exported environment process-wide (#328). repo_root()
# (config.sh) already scrubs its OWN rev-parse subshell (#279), but this script
# then runs its own git MUTATIONS below (worktree add / branch --list / fetch /
# submodule update); a tainted GIT_DIR/GIT_COMMON_DIR forwarded from a git hook
# would redirect those to an OUTER repo — the worktree dir lands here but the new
# branch ref lands there, a split-brain state (dynamically reproduced in #328's
# review). `cd "$root"` does not re-anchor git while GIT_DIR is set, so unset the
# whole set here, before repo_root() and every other git call. Deliberately NO
# `|| true`: a readonly GIT_DIR makes `unset` fail, which under `set -e` aborts
# LOUDLY before any mutation — the fail-loud outcome, never a silent wrong-repo
# write. Uses config.sh's shared _git_env_scrub_names (#356 / #355) so the scrub
# set — static vars PLUS the dynamic GIT_CONFIG_KEY_<n>/VALUE_<n> pairs — stays in
# lockstep with repo_root()'s and worktree-rm.sh's, one source of truth.
# shellcheck disable=SC2046  # intentional word-split: unset each scrub var by name
unset $(_git_env_scrub_names)

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

# Wire the platform CLI's token into git so HTTPS pushes work from this
# worktree (#810). `gh`/`glab` is the authenticated identity everywhere in this
# pipeline, but git has no way to reach it on its own and dies at ship time with
#
#     fatal: could not read Username for 'https://github.com'
#
# — after the full pre-push suite has already run. An interactive operator fixes
# that in one line; a DETACHED tmux/container golem has nobody to answer and
# dead-end parks with the work complete and only delivery failed. Same
# make-this-worktree-usable intent as the local-file copy above.
#
# SCOPE (measured, #810): `git config --local` from inside a linked worktree
# writes the SHARED .git/config unless `extensions.worktreeConfig` is enabled
# (it is not, by default). That is deliberate here — the seed is durable across
# teardown and fixes every later worktree of this repo, which is exactly what
# the hand-applied workaround did. worktree-rm.sh correspondingly does NOT
# unset it.
#
# Best-effort, and quiet on the paths where doing nothing is correct: no
# remote, a non-HTTPS remote (ssh uses keys and needs no helper), an
# unrecognized host, or the platform CLI absent all no-op rather than writing
# spurious config or hard-failing an otherwise-good worktree.
#
# Reuses the remote already derived for the base-ref fetch above so there is
# only one notion of "which remote"; GOLEM_BASE_REF may carry no remote
# component (e.g. a bare `HEAD`), hence the `origin` fallback.
cred_remote="${base_remote:-origin}"
cred_url="$(command git remote get-url "$cred_remote" 2>/dev/null || true)"
case "$cred_url" in
    https://*)
        # scheme://host — drop any `userinfo@`, then the path at the first `/`.
        cred_hostpath="${cred_url#https://}"
        cred_hostpath="${cred_hostpath#*@}"
        cred_host="https://${cred_hostpath%%/*}"
        # Same platform table the workflow skills use (next-issue § Platform
        # Detection): github.com/ghe. -> gh, gitlab.com/gitlab. -> glab.
        cred_cli=""
        case "$cred_host" in
            *github.com | *ghe.*) cred_cli="gh" ;;
            *gitlab.com | *gitlab.*) cred_cli="glab" ;;
        esac
        if [ -n "$cred_cli" ] && command -v "$cred_cli" >/dev/null 2>&1; then
            cred_helper="!$cred_cli auth git-credential"
            command git -C "$wt" config --local \
                "credential.${cred_host}.helper" "$cred_helper" || true
            # Verify rather than assume: a silent failure to set this resurfaces
            # much later as the original `fatal:`, at ship time, with no clue
            # pointing back here. Same fail-loud posture as the submodule
            # warning above.
            if [ "$(command git -C "$wt" config --get \
                "credential.${cred_host}.helper" 2>/dev/null)" = "$cred_helper" ]; then
                command echo "  seeded git credential helper ($cred_cli) for $cred_host"
            else
                command echo "worktree-new: WARNING — could not seed the git credential" \
                    "helper for $cred_host; pushes from $wt may fail with" \
                    "'could not read Username'" >&2
            fi
        fi
        ;;
esac

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
# $(golem_model_flag) splices ` --model "…"` after each `claude` when GOLEM_MODEL
# is set (so the copy-paste hint already carries the operator's chosen model),
# and expands to nothing — byte-identical hint — when unset.
MODEL_FLAG="$(golem_model_flag)"
command echo "  tmux new-session -d -s golem-$N -c \"$root/$wt\" -e GOLEM_ID=golem-$N \"claude$MODEL_FLAG --permission-mode auto '/workflow:next-issue $N --level 4' ; claude$MODEL_FLAG --permission-mode auto '/workflow:ship-issue'\""
