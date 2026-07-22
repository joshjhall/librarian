#!/usr/bin/env bash
# golem-attach.sh — attach to issue N's golem session (worktree or container).
#
# Replaces the containers `golem-attach` just recipe so the golem flow runs
# WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Tries the golem-N worktree tmux session first; else the container golem's
# `claude` session via `docker exec` (clean failure if neither exists).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_STATUS_DIR   (.worktrees/.status)
#
# Usage: golem-attach.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "golem-attach: N must be an issue number, got '$N'" >&2
    exit 2
fi

if tmux has-session -t "golem-$N" 2>/dev/null; then
    exec tmux attach -t "golem-$N"
fi

root="$(repo_root)"
status_dir="$root/$GOLEM_STATUS_DIR"
shopt -s nullglob
for f in "$status_dir"/*.json; do
    if [ "$(jq -r '.issue // empty' "$f" 2>/dev/null)" = "$N" ]; then
        ctr="$(jq -r '.container // empty' "$f" 2>/dev/null)"
        if [ -n "$ctr" ]; then
            exec docker exec -it "$ctr" tmux attach -t claude
        fi
    fi
done

command echo "golem-attach: no golem-$N tmux session and no container golem for issue $N." >&2
command echo "  Check 'golem-status.sh' for active golems." >&2
exit 1
