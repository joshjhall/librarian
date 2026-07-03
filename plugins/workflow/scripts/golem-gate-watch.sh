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
#           (golem-notify.sh) and classified `gate` vs `idle` vs `escalation`.
#           TTY-free, works for ALL golems incl. headless/container, carries
#           golem-id attribution. A plan-gate `ExitPlanMode` shows only as a
#           generic `gate` here; a mid-flight `escalation` (issue #176) surfaces
#           in the same BLOCKED set but is labelled distinctly ("escalation — …").
#   panes — `tmux capture-pane` on live `golem-*` sessions, matched against the
#           modal PROMPT OVERLAY ("Do you want to proceed?" / the ExitPlanMode
#           plan prompt). The "capture-pane is blank until exit" caveat applies
#           to scrolling WORK OUTPUT, not the prompt overlay, which renders over
#           the alt-screen and is reliably scrapeable — and is the better
#           catcher of plan-gate prompts. Live worktree golems only.
#
# Output (one line per fresh gate): "<golem-id>\t<message>"
#
# Liveness channel (issue #38) — the third, ORTHOGONAL signal. Gate-watch is
# edge-triggered on permission prompts; a golem in a long uninterrupted phase
# (background review harness, a multi-minute test run, a big implementation
# burst) emits NO prompts, so a healthy-but-quiet golem is indistinguishable
# from a hung one. The liveness sweep turns "absence of a gate" into a positive
# heartbeat: per live/cached golem it derives a cheap progress proxy (the newest
# mtime among its worktree index/dir and status-cache file) and classifies it
#   "golem-N alive, advancing" (activity within GOLEM_STALL_THRESHOLD), or
#   "golem-N: possible stall — no progress for Nm" (older).
# A golem currently sitting at a fresh feed gate is reported as gated, NOT
# stalled (the two are distinct — a gate is expected supervision; a stall is
# the suspect case). This is a SOFT, advisory signal: it never kills, blocks, or
# fails a golem — it only tells the operator which ones to actually look at.
#
# Modes:
#   --once         (default) feed snapshot: current fresh gates, then exit 0
#   --stream                 feed poll loop: emit on TRANSITION into a fresh
#                            gate (dedupe standing gates), until killed
#   --once-panes             pane snapshot: live golem-* sessions at a prompt
#   --stream-panes           pane poll loop: emit on transition, until killed
#   --once-liveness          liveness snapshot: per-golem heartbeat/stall, exit 0
#   --stream-liveness        liveness poll loop: re-emit each golem's heartbeat
#                            every GOLEM_HEARTBEAT_INTERVAL, until killed
#
# Tunables (env; see config.sh for worktree/status-dir tunables):
#   GOLEM_BLOCK_TTL          feed gate freshness window, seconds (default 3600)
#   GOLEM_WATCH_INTERVAL     poll interval for --stream*, seconds (default 5)
#   GOLEM_STALL_THRESHOLD    liveness stall window, seconds (default 1200)
#   GOLEM_HEARTBEAT_INTERVAL liveness poll interval, seconds (default 60)
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

# The drive block at the bottom is wrapped in a main-guard so SOURCING this
# script (the unit tests do, to call _fmt_age / pane_is_* / emit_transitions
# directly) defines only the functions and never runs the snapshot loop or its
# `exit` calls. When the script is EXECUTED, `${BASH_SOURCE[0]}` equals `$0`, the
# guard fires, and behavior is byte-for-byte identical to before it was added.
# These tunables stay at top level (assigned whether sourced or executed) so a
# sourced helper that reads `$ttl` still sees its default — harmless and cheap.
ttl="${GOLEM_BLOCK_TTL:-3600}"
interval="${GOLEM_WATCH_INTERVAL:-5}"
stall_threshold="${GOLEM_STALL_THRESHOLD:-1200}"
heartbeat_interval="${GOLEM_HEARTBEAT_INTERVAL:-60}"

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
# legacy `blocked`, or a mid-flight `escalation`) within the freshness window —
# identical semantics to the golem-status.sh BLOCKED list (kept in lockstep so
# the two never drift). An `escalation` line is labelled "escalation — <message>"
# so the reader can tell a judgement call apart from a routine permission gate.
# Requires jq; a no-op (no output, success) when jq or the feed is absent.
feed_snapshot() {
    local feed="$1"
    [ -f "$feed" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # A no-`ts` (or empty-`ts`) line bypasses the TTL and counts as fresh — by
    # design, honoring legacy lines written before the timestamp convention
    # (`else true`). Guarding the type/emptiness first is load-bearing: feeding
    # null/"" to `fromdateiso8601` aborts jq with a non-zero exit, the `2>/dev/null`
    # swallows it, and the snapshot returns EMPTY — silently dropping every gated
    # golem (issue #24). The TTL bypass is bounded: `group_by | map(.[-1])` keeps
    # only each golem's MOST-RECENT line, so a later `idle`/`gate` (which always
    # carries a `.ts` now) supersedes a stale no-`ts` entry rather than it living
    # forever.
    /usr/bin/tail -n 200 "$feed" 2>/dev/null |
        jq -rs --argjson ttl "$ttl" '
            (now) as $now
            | group_by(.golem)
            | map(.[-1])
            | map(select((.event == "gate" or .event == "blocked" or .event == "escalation")
                         and (if (.ts | type) == "string" and .ts != ""
                              then (($now - (.ts | fromdateiso8601)) < $ttl)
                              else true end)))
            | .[]
            | (.message // "awaiting decision") as $m
            | if .event == "escalation" then "\(.golem)\tescalation — \($m)"
              else "\(.golem)\t\($m)" end
          ' 2>/dev/null |
        /usr/bin/sort -u
}

# --- portable string→string map (bash 3.2 has no `declare -A`) --------------
# Backs emit_transitions' cross-call state without bash-4 associative arrays, so
# this script runs under macOS's stock bash 3.2. The map is a newline-separated
# string of "<key>\t<value>" records; keys (golem ids) carry no tab/newline and
# values (gate messages) carry no newline. Linear scan is ample for the handful
# of golems ever tracked at once. See CLAUDE.md § Key conventions (runtime policy).
_map_get() { # _map_get <map> <key> -> value on stdout (empty when absent)
    local map="$1" key="$2" k v
    while IFS=$'\t' read -r k v; do
        [ "$k" = "$key" ] && {
            command printf '%s' "$v"
            return 0
        }
    done <<<"$map"
    return 0
}

_map_set() { # _map_set <map> <key> <value> -> new map on stdout (upsert)
    local map="$1" key="$2" val="$3" k v found=0 out=""
    while IFS=$'\t' read -r k v; do
        [ -z "$k" ] && continue
        if [ "$k" = "$key" ]; then
            out="${out}${key}"$'\t'"${val}"$'\n'
            found=1
        else
            out="${out}${k}"$'\t'"${v}"$'\n'
        fi
    done <<<"$map"
    [ "$found" -eq 1 ] || out="${out}${key}"$'\t'"${val}"$'\n'
    command printf '%s' "$out"
}

# _set_has <space-delimited-set> <token> — membership test, boundary-safe.
_set_has() {
    case " ${1} " in
        *" ${2} "*) return 0 ;;
    esac
    return 1
}

# Emit only on TRANSITION into a fresh gate. Tracks the last-emitted message per
# golem in the flat-string map above: a standing gate (same golem, same message)
# is suppressed; a golem that clears (drops out of the snapshot) is forgotten so
# a later re-gate fires again; a changed message re-emits. `prime=1` records the
# current state WITHOUT emitting (so --stream does not dump pre-existing gates as
# if they were new on startup).
LAST_EMIT=""
emit_transitions() {
    local snapshot="$1" prime="${2:-0}"
    local seen=" " golem msg prev
    while IFS=$'\t' read -r golem msg; do
        [ -z "$golem" ] && continue
        seen="${seen}${golem} "
        prev="$(_map_get "$LAST_EMIT" "$golem")"
        if [ "$prev" != "$msg" ]; then
            LAST_EMIT="$(_map_set "$LAST_EMIT" "$golem" "$msg")"
            [ "$prime" = "1" ] || /usr/bin/printf '%s\t%s\n' "$golem" "$msg"
        fi
    done <<<"$snapshot"
    # Forget golems no longer gated, so a future re-gate is a fresh transition:
    # keep only records whose key is in this snapshot's `seen` set.
    local k v newmap=""
    while IFS=$'\t' read -r k v; do
        [ -z "$k" ] && continue
        if _set_has "$seen" "$k"; then
            newmap="${newmap}${k}"$'\t'"${v}"$'\n'
        fi
    done <<<"$LAST_EMIT"
    LAST_EMIT="$newmap"
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
# Liveness channel (issue #38)
# ---------------------------------------------------------------------------
# mtime of a path in epoch seconds, or empty if it does not exist / can't stat.
# GNU `stat -c %Y` and BSD `stat -f %m` differ; try GNU first, then BSD. All
# failures are swallowed (advisory signal — never fail a golem over a stat).
_mtime_epoch() {
    local path="$1" m=""
    [ -e "$path" ] || return 0
    m="$(/usr/bin/stat -c %Y "$path" 2>/dev/null || /usr/bin/stat -f %m "$path" 2>/dev/null || true)"
    case "$m" in
        '' | *[!0-9]*) return 0 ;;
        *) command echo "$m" ;;
    esac
}

# Newest mtime (epoch seconds) among a golem's cheap progress proxies: its
# status-cache JSON, and its worktree's git index + working-tree dir. The index
# is touched by every git operation (add/commit/checkout); the dir mtime moves
# when top-level entries change; the status JSON is rewritten as the golem
# advances phases. We deliberately do NOT walk the whole tree (too costly per
# tick). Prints the max epoch, or empty when nothing is found.
_golem_last_activity() {
    local n="$1" root="$2" status_dir="$3"
    local candidates=(
        "$status_dir/golem-$n.json"
        "$status_dir/issue-$n.json"
        "$root/$GOLEM_WORKTREE_DIR/issue-$n"
        "$root/$GOLEM_WORKTREE_DIR/issue-$n/.git"
        "$root/$GOLEM_WORKTREE_DIR/issue-$n/.git/index"
    )
    local p m best=""
    for p in "${candidates[@]}"; do
        m="$(_mtime_epoch "$p")"
        [ -z "$m" ] && continue
        if [ -z "$best" ] || [ "$m" -gt "$best" ]; then
            best="$m"
        fi
    done
    [ -n "$best" ] && command echo "$best"
}

# Human-friendly "Nm" / "Ns" for a non-negative second count.
_fmt_age() {
    local s="$1"
    if [ "$s" -ge 60 ]; then
        command echo "$((s / 60))m"
    else
        command echo "${s}s"
    fi
}

# Print one liveness line per known golem: "<golem>\t<message>". A golem is
# "known" if it has a live golem-* tmux session OR a status-cache file (so the
# sweep covers headless/container golems with no TTY). A golem currently at a
# fresh feed gate is reported as gated rather than stalled. Golems with no
# detectable activity proxy at all are skipped (nothing to assert about them).
# No-op (success) when the status dir is unresolved.
liveness_snapshot() {
    local status_dir="$1" feed="$2"
    local root
    root="$(repo_root 2>/dev/null || true)"
    [ -z "$root" ] && return 0

    # Set of golem numbers to consider: union of live sessions + cache files.
    # Space-delimited string set (dedup on insert) — bash 3.2 has no associative
    # arrays; keys are bare integers so a space-delimited set is exact and cheap.
    local golems=" " sess n f
    if command -v tmux >/dev/null 2>&1; then
        while IFS= read -r sess; do
            [ -z "$sess" ] && continue
            n="${sess#golem-}"
            _set_has "$golems" "$n" || golems="${golems}${n} "
        done < <(tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' || true)
    fi
    if [ -n "$status_dir" ] && [ -d "$status_dir" ]; then
        for f in "$status_dir"/golem-*.json "$status_dir"/issue-*.json; do
            [ -e "$f" ] || continue
            n="${f##*/}"
            n="${n#golem-}"
            n="${n#issue-}"
            n="${n%.json}"
            case "$n" in
                '' | *[!0-9]*) continue ;;
                *) _set_has "$golems" "$n" || golems="${golems}${n} " ;;
            esac
        done
    fi
    # Empty set is exactly the sentinel single space.
    [ "$golems" = " " ] && return 0

    # Golems currently at a fresh feed gate — reported as gated, not stalled.
    local gated=" "
    if [ -n "$feed" ] && [ -f "$feed" ]; then
        local g rest
        while IFS=$'\t' read -r g rest; do
            [ -z "$g" ] && continue
            n="${g#golem-}"
            _set_has "$gated" "$n" || gated="${gated}${n} "
        done < <(feed_snapshot "$feed")
    fi

    local now act age
    now="$(/usr/bin/date +%s)"
    # Stable numeric order so successive snapshots line up for the operator.
    for n in $(command echo "$golems" | /usr/bin/tr ' ' '\n' | /usr/bin/sort -n); do
        [ -z "$n" ] && continue
        if _set_has "$gated" "$n"; then
            /usr/bin/printf '%s\t%s\n' "golem-$n" "gated — awaiting decision (not a stall)"
            continue
        fi
        act="$(_golem_last_activity "$n" "$root" "$status_dir")"
        [ -z "$act" ] && continue
        age=$((now - act))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$stall_threshold" ]; then
            /usr/bin/printf '%s\t%s\n' "golem-$n" "possible stall — no progress for $(_fmt_age "$age")"
        else
            /usr/bin/printf '%s\t%s\n' "golem-$n" "alive, advancing (last activity $(_fmt_age "$age") ago)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------
# Main-guard: only when EXECUTED (not sourced) do we parse the mode argument and
# enter the drive block. Sourcing the script (unit tests) defines the functions
# above and stops here, so calling _fmt_age / pane_is_* / emit_transitions in a
# test never triggers the snapshot loops or the `exit` calls below.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

    mode="--once"
    case "${1:-}" in
        --once | --stream | --once-panes | --stream-panes | --once-liveness | --stream-liveness) mode="$1" ;;
        "") mode="--once" ;;
        *)
            command echo "golem-gate-watch: unknown mode '$1' (want --once|--stream|--once-panes|--stream-panes|--once-liveness|--stream-liveness)" >&2
            exit 2
            ;;
    esac

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
        --once-liveness)
            liveness_snapshot "$status_dir" "$feed"
            exit 0
            ;;
        --stream-liveness)
            # A heartbeat is a POSITIVE periodic signal, so (unlike gates) it is NOT
            # transition-deduped — each tick re-emits every golem's current liveness,
            # confirming "still alive" even when nothing changed. The sweep is cheap
            # (a handful of stats per golem); GOLEM_HEARTBEAT_INTERVAL paces it.
            while :; do
                liveness_snapshot "$status_dir" "$feed"
                /usr/bin/sleep "$heartbeat_interval"
            done
            ;;
    esac

fi
