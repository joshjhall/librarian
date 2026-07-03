#!/usr/bin/env bash
# golem-status.sh — show the central golem status table + which golems are
# BLOCKED (TTY-free).
#
# Replaces the containers `golems` just recipe so the golem flow runs WITHOUT
# `just`, on host / bare Linux / inside a devcontainer.
#
# Reads <GOLEM_STATUS_DIR>/*.json (per-golem status cache) + live golem-* tmux
# sessions and the Notification feed (<GOLEM_STATUS_DIR>/feed.jsonl); PR + issue
# -label state remains authoritative (the cache only fills gaps). pool.json is
# operator policy, NOT a golem-status file, so it is excluded from the golem-row
# glob and surfaced separately in the pool header.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_STATUS_DIR   (.worktrees/.status)
#
# Usage: golem-status.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

root="$(repo_root)"
status_dir="$root/$GOLEM_STATUS_DIR"
feed="$status_dir/feed.jsonl"
pool="$status_dir/pool.json"
shopt -s nullglob

# pool.json is operator policy, NOT a golem-status file — keep it out of the
# golem-row glob (else it renders as a bogus "?" row). It's surfaced in the
# pool header below instead.
cache=()
for f in "$status_dir"/*.json; do
    [ "$f" = "$pool" ] && continue
    cache+=("$f")
done

sessions="$(tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' || true)"
if [ "${#cache[@]}" -eq 0 ] && [ -z "$sessions" ] && [ ! -f "$pool" ]; then
    command echo "No active golems (no $status_dir/*.json, no golem-* tmux sessions)."
    exit 0
fi

# Pool header: size, slots in use, backlog depth, and the accepting state.
# Defensive `// "-"` fallbacks mirror the golem-row jq style for absent fields.
if [ -f "$pool" ]; then
    jq -r '"Pool: size=\(.size // "-")  slots=\((.slots // []) | length)/\(.size // "-")  backlog=\(.backlog_depth // "-")  accepting=\(.accepting // "-")"' \
        "$pool" 2>/dev/null || command echo "Pool: (unreadable $pool)"
    command echo ""
fi

/usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
    GOLEM ISSUE BRANCH PR STATE PHASE BLOCKING
for f in "${cache[@]}"; do
    jq -r '[
        (.golem // "?"),
        (.issue // "?" | tostring),
        (.branch // "-"),
        (.pr // "-" | tostring),
        (.state // "-"),
        (.phase // "-"),
        (if .blocking then "YES" else "-" end)
    ] | @tsv' "$f" 2>/dev/null |
        while IFS=$'\t' read -r g i b p s ph bl; do
            /usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' "$g" "$i" "$b" "$p" "$s" "$ph" "$bl"
        done
done

# Live sessions with no cache file yet.
for sess in $sessions; do
    n="${sess#golem-}"
    if [ ! -e "$status_dir/golem-$n.json" ] && [ ! -e "$status_dir/issue-$n.json" ]; then
        /usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
            "$sess" "$n" "-" "-" "(live)" "-" "-"
    fi
done

command echo ""
command echo "BLOCKED (needs a human decision):"
blocked=0
for f in "${cache[@]}"; do
    if [ "$(jq -r '.blocking // false' "$f" 2>/dev/null)" = "true" ]; then
        n="$(jq -r '.issue // empty' "$f" 2>/dev/null)"
        command echo "  golem-$n — golem-attach.sh $n"
        blocked=1
    fi
done

# Fresh-gate detection from the feed is delegated to golem-gate-watch.sh
# (--once snapshot) so this BLOCKED list and the proactive `--stream` watch
# share ONE source of truth and can never drift. The helper applies the same
# rule: a golem is BLOCKED only when its most-recent feed line is a fresh `gate`
# (legacy `blocked` honored, a mid-flight `escalation` per issue #176, or a
# `dead-end` per issue #180) within GOLEM_BLOCK_TTL; an `idle` emitted once the
# golem resumes supersedes and clears it. It emits "<golem>\t<message>", already
# labelling an escalation "escalation — …" and a dead-end "dead-end — …";
# reformat to the "  golem — message" display here.
if [ -f "$feed" ] && [ -x "$SCRIPT_DIR/golem-gate-watch.sh" ]; then
    feed_blocked="$(
        "$SCRIPT_DIR/golem-gate-watch.sh" --once 2>/dev/null |
            /usr/bin/awk -F'\t' 'NF { printf "  %s — %s\n", $1, $2 }'
    )"
    if [ -n "$feed_blocked" ]; then
        /usr/bin/printf '%s\n' "$feed_blocked"
        blocked=1
    fi
fi
[ "$blocked" -eq 0 ] && command echo "  (none)"

# Liveness/heartbeat (issue #38) — a SOFT, advisory signal, distinct from the
# BLOCKED gate list above. Delegated to golem-gate-watch.sh --once-liveness so
# the pulled status view and the proactive --stream-liveness watch share ONE
# source of truth (same rule, same stall threshold) and can never drift. Each
# line is either "golem-N alive, advancing ..." or "golem-N possible stall ...";
# a golem at a fresh gate is reported as gated here, not stalled. Never
# kills/blocks a golem — it only points the operator at the suspect ones.
if [ -x "$SCRIPT_DIR/golem-gate-watch.sh" ]; then
    command echo ""
    command echo "LIVENESS (advisory — heartbeat / possible stall):"
    liveness="$(
        "$SCRIPT_DIR/golem-gate-watch.sh" --once-liveness 2>/dev/null |
            /usr/bin/awk -F'\t' 'NF { printf "  %s — %s\n", $1, $2 }'
    )"
    if [ -n "$liveness" ]; then
        /usr/bin/printf '%s\n' "$liveness"
    else
        command echo "  (no liveness proxy available)"
    fi
fi

if [ -f "$feed" ]; then
    command echo ""
    command echo "Recent feed ($feed):"
    /usr/bin/tail -n 10 "$feed"
fi
