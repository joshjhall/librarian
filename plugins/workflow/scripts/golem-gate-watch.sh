#!/usr/bin/env bash
# golem-gate-watch.sh — proactive gate-watch for the orchestrate golem flow.
#
# The orchestrate live session monitors golem PRs but has no PROACTIVE signal
# for a golem parked at a permission gate (the `git push` / `gh pr create` /
# `gh pr merge` `ask` rules, or a plan-gate `ExitPlanMode` prompt). Golems wait,
# silently, until the operator happens to run golem-status.sh — which defeats
# the supervised-auto model (the gates ARE the supervision). This helper turns
# the pull check into a push signal: it emits one line per FRESH gate, so the
# harness `Monitor` tool can notify the operator the moment a golem blocks.
#
# Two CO-EQUAL channels, each catching what the other misses:
#
#   feed  — `<GOLEM_STATUS_DIR>/feed.jsonl`, written by the Notification hook
#           (golem-notify.sh) and classified `gate` vs `idle`. TTY-free, works
#           for ALL golems incl. headless/container, carries golem-id
#           attribution. A plan-gate `ExitPlanMode` shows only as a generic
#           `gate` here.
#   panes — `tmux capture-pane` on live `golem-*` sessions, matched against the
#           modal PROMPT OVERLAY ("Do you want to proceed?" / the ExitPlanMode
#           plan prompt). The "capture-pane is blank until exit" caveat applies
#           to scrolling WORK OUTPUT, not the prompt overlay, which renders over
#           the alt-screen and is reliably scrapeable — and is the better
#           catcher of plan-gate prompts. Live worktree golems only.
#
# Output (one line per fresh gate): "<golem-id>\t<message>"
#
# Modes:
#   --once         (default) feed snapshot: current fresh gates, then exit 0
#   --stream                 feed poll loop: emit on TRANSITION into a fresh
#                            gate (dedupe standing gates), until killed
#   --once-panes             pane snapshot: live golem-* sessions at a prompt
#   --stream-panes           pane poll loop: emit on transition, until killed
#
# Tunables (env; see config.sh for worktree/status-dir tunables):
#   GOLEM_BLOCK_TTL          feed gate freshness window, seconds (default 3600)
#   GOLEM_WATCH_INTERVAL     poll interval for --stream*, seconds (default 5)
#
# Never blocks a golem and never hangs on a missing feed/tmux: errors are
# swallowed and a snapshot mode always exits 0. The `--stream*` loops carry NO
# "zero golems remain -> stop" exit: a transient zero-golem window (the handoff
# beat where one golem's session is killed and the next is created) never
# terminates the watch; it stops only when the operator/harness kills it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

mode="--once"
case "${1:-}" in
    --once | --stream | --once-panes | --stream-panes) mode="$1" ;;
    "") mode="--once" ;;
    *)
        command echo "golem-gate-watch: unknown mode '$1' (want --once|--stream|--once-panes|--stream-panes)" >&2
        exit 2
        ;;
esac

ttl="${GOLEM_BLOCK_TTL:-3600}"
interval="${GOLEM_WATCH_INTERVAL:-5}"

# Resolve the MAIN checkout's status dir (the feed lives there even when invoked
# from a worktree). repo_root (from config.sh) is bare-repo-safe.
resolve_status_dir() {
    local root
    root="$(repo_root 2>/dev/null || true)"
    [ -z "$root" ] && return 1
    command echo "$root/$GOLEM_STATUS_DIR"
}

# ---------------------------------------------------------------------------
# Feed channel
# ---------------------------------------------------------------------------
# Print the current fresh-gate set from the feed, one "<golem>\t<message>" line
# each. A golem is gated only when its MOST-RECENT feed line is a `gate` (or
# legacy `blocked`) within the freshness window — identical semantics to the
# golem-status.sh BLOCKED list (kept in lockstep so the two never drift).
# Requires jq; a no-op (no output, success) when jq or the feed is absent.
feed_snapshot() {
    local feed="$1"
    [ -f "$feed" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    /usr/bin/tail -n 200 "$feed" 2>/dev/null |
        jq -rs --argjson ttl "$ttl" '
            (now) as $now
            | group_by(.golem)
            | map(.[-1])
            | map(select((.event == "gate" or .event == "blocked")
                         and (($now - (.ts | fromdateiso8601)) < $ttl)))
            | .[] | "\(.golem)\t\(.message // "awaiting decision")"
          ' 2>/dev/null |
        /usr/bin/sort -u
}

# Emit only on TRANSITION into a fresh gate. Tracks the last-emitted message per
# golem in an associative array: a standing gate (same golem, same message) is
# suppressed; a golem that clears (drops out of the snapshot) is forgotten so a
# later re-gate fires again; a changed message re-emits. `prime=1` records the
# current state WITHOUT emitting (so --stream does not dump pre-existing gates as
# if they were new on startup).
declare -A LAST_EMIT
emit_transitions() {
    local snapshot="$1" prime="${2:-0}"
    declare -A seen=()
    local golem msg
    while IFS=$'\t' read -r golem msg; do
        [ -z "$golem" ] && continue
        seen["$golem"]=1
        if [ "${LAST_EMIT[$golem]:-}" != "$msg" ]; then
            LAST_EMIT["$golem"]="$msg"
            [ "$prime" = "1" ] || /usr/bin/printf '%s\t%s\n' "$golem" "$msg"
        fi
    done <<<"$snapshot"
    # Forget golems no longer gated, so a future re-gate is a fresh transition.
    for golem in "${!LAST_EMIT[@]}"; do
        [ -n "${seen[$golem]:-}" ] || unset 'LAST_EMIT[$golem]'
    done
}

# ---------------------------------------------------------------------------
# Pane channel
# ---------------------------------------------------------------------------
# Modal prompt-overlay patterns. A live golem at a permission/plan gate paints
# one of these over its alt-screen; matching them is reliable (unlike scraping
# scrolling work output). Extend these lists as new prompt shapes appear.
pane_is_plan_gate() {
    case "$1" in
        *"Ready to code"*) return 0 ;;
        *"ready to code"*) return 0 ;;
        *"Would you like to proceed"*) return 0 ;;
        *"Here is Claude's plan"*) return 0 ;;
        *"Yes, and use auto mode"*) return 0 ;;
    esac
    return 1
}

# Generic permission-decision overlay (Bash/Edit/push/PR `ask` rules etc.).
pane_is_gate() {
    case "$1" in
        *"Do you want to proceed"*) return 0 ;;
    esac
    return 1
}

# Print the current set of live golem-* sessions sitting at a prompt overlay,
# one "<golem>\t<message>" line each. No-op (success) when tmux is absent.
panes_snapshot() {
    command -v tmux >/dev/null 2>&1 || return 0
    local sessions sess pane
    sessions="$(tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' || true)"
    [ -z "$sessions" ] && return 0
    for sess in $sessions; do
        pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null || true)"
        [ -z "$pane" ] && continue
        if pane_is_plan_gate "$pane"; then
            /usr/bin/printf '%s\t%s\n' "$sess" "plan gate — ExitPlanMode awaiting approval"
        elif pane_is_gate "$pane"; then
            /usr/bin/printf '%s\t%s\n' "$sess" "permission gate — awaiting decision"
        fi
    done
}

# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------
status_dir="$(resolve_status_dir || true)"
feed="${status_dir:+$status_dir/feed.jsonl}"

case "$mode" in
    --once)
        [ -n "$feed" ] && feed_snapshot "$feed"
        exit 0
        ;;
    --once-panes)
        panes_snapshot
        exit 0
        ;;
    --stream)
        # Prime from the current state so pre-existing gates are not replayed as
        # new, then emit only genuine transitions thereafter.
        [ -n "$feed" ] && emit_transitions "$(feed_snapshot "$feed")" 1
        while :; do
            /usr/bin/sleep "$interval"
            [ -n "$feed" ] && emit_transitions "$(feed_snapshot "$feed")" 0
        done
        ;;
    --stream-panes)
        emit_transitions "$(panes_snapshot)" 1
        while :; do
            /usr/bin/sleep "$interval"
            emit_transitions "$(panes_snapshot)" 0
        done
        ;;
esac
