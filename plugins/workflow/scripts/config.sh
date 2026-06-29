#!/usr/bin/env bash
# config.sh — shared, env-overridable configuration for the workflow plugin's
# bundled golem/worktree scripts. Source this near the top of every script:
#
#     SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
#     # shellcheck source=./config.sh
#     . "$SCRIPT_DIR/config.sh"
#
# These scripts were de-coupled from the containers repo's justfile so the
# golem/worktree flow runs WITHOUT `just` — on a host, on bare Linux, or inside
# a devcontainer. Every tunable below has a sane default and is overridable from
# the environment, so a project can relocate worktrees or rename branches
# without editing the scripts.
#
# Tunables (all overridable via the environment):
#   GOLEM_WORKTREE_DIR   Directory (repo-root-relative) holding per-issue
#                        worktrees.                      Default: .worktrees
#   GOLEM_STATUS_DIR     Directory holding golem status JSON + feed.jsonl.
#                        Default: <GOLEM_WORKTREE_DIR>/.status
#   GOLEM_BRANCH_PREFIX  Branch-name prefix; the branch for issue N is
#                        "<prefix><N>".                  Default: feature/issue-
#   GOLEM_BASE_REF       The ref new worktree branches fork from.
#                        Default: origin/main
#   GOLEM_WORKTREE_LOCAL_FILES
#                        Space-separated list of gitignored, machine-local files
#                        copied from the main checkout into a fresh worktree so a
#                        push from inside it has what it needs (e.g. .env,
#                        .claude/settings.local.json). Empty disables copying.
#                        Default: ".env .claude/settings.local.json"
#   GOLEM_STALL_THRESHOLD
#                        Liveness window, seconds. A golem with no detectable
#                        progress (worktree / status-cache activity) for longer
#                        than this is flagged a *possible stall* (SOFT, advisory
#                        — never auto-killed).            Default: 1200 (20 min)
#   GOLEM_HEARTBEAT_INTERVAL
#                        Poll interval for the liveness stream (--stream-liveness),
#                        seconds.                         Default: 60
#
# This file only DEFINES variables (no side effects beyond `export`), so it is
# safe to source from any script.

# Use full paths / the `command` builtin for coreutils throughout these scripts:
# aliases or shell functions can change output format and break parsing.

# Per-issue worktree dir, repo-root-relative.
: "${GOLEM_WORKTREE_DIR:=.worktrees}"

# Golem status cache + feed, repo-root-relative (sits under the worktree dir by
# default so it travels with it).
: "${GOLEM_STATUS_DIR:=${GOLEM_WORKTREE_DIR}/.status}"

# Branch naming: issue N -> "<GOLEM_BRANCH_PREFIX><N>".
: "${GOLEM_BRANCH_PREFIX:=feature/issue-}"

# Ref that new worktree branches are created from.
: "${GOLEM_BASE_REF:=origin/main}"

# Gitignored machine-local files a push from inside a worktree needs.
: "${GOLEM_WORKTREE_LOCAL_FILES:=.env .claude/settings.local.json}"

# Liveness/heartbeat (SOFT, advisory — never auto-kills a golem):
# how long a golem may show no progress before it is flagged a possible stall,
# and the poll interval of the liveness stream.
: "${GOLEM_STALL_THRESHOLD:=1200}"
: "${GOLEM_HEARTBEAT_INTERVAL:=60}"

export GOLEM_WORKTREE_DIR GOLEM_STATUS_DIR GOLEM_BRANCH_PREFIX GOLEM_BASE_REF \
    GOLEM_WORKTREE_LOCAL_FILES GOLEM_STALL_THRESHOLD GOLEM_HEARTBEAT_INTERVAL

# repo_root — print the main checkout's root directory, bare-repo-safe.
#
# `git rev-parse --show-toplevel` ABORTS in a bare repository (the worktree-host
# layout the golem flow runs on). Resolve the root from the git COMMON dir
# instead, whose parent is the main checkout — cwd- and bare-independent, and
# from inside a worktree it still returns the MAIN root (worktrees share the
# common dir), which is what the scripts want.
#
# Prints the absolute root on stdout and returns 0; prints nothing and returns 1
# when not inside a git repository.
repo_root() {
    local common_dir
    common_dir="$(/usr/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$common_dir" ]; then
        command echo "repo-root: not inside a git repository" >&2
        return 1
    fi
    # --path-format=absolute should guarantee absolute, but stay defensive.
    case "$common_dir" in
        /*) ;;
        *) common_dir="$(/usr/bin/pwd)/$common_dir" ;;
    esac
    /usr/bin/dirname "$common_dir"
}
