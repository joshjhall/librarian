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
#   GOLEM_STATUS_DIR     (.worktrees/.status)
#   GOLEM_SWEEP_INTERVAL sweep cadence for --watch, seconds. Unset -> the
#                        level-scaled default from autonomy-resolve.sh (#304).
#
# Usage:
#   golem-status.sh                        one-shot render (default)
#   golem-status.sh --watch [--level N] [--interval S]
#                                          re-render on a level-scaled interval
#                                          until killed (orchestrator Phase M
#                                          default-on sweep, #304)
#
# --watch interval precedence (first present wins):
#   --interval S  >  GOLEM_SWEEP_INTERVAL  >  autonomy-resolve sweep-interval
#   --level N  >  autonomy-resolve sweep-interval (L1 default).
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

root="$(repo_root)"
status_dir="$root/$GOLEM_STATUS_DIR"
feed="$status_dir/feed.jsonl"
pool="$status_dir/pool.json"
scrape="$SCRIPT_DIR/golem-token-scrape.sh"
shopt -s nullglob

# _now_iso — current UTC time as an ISO-8601 Z timestamp (mirrors the
# golem-notify.sh feed-line idiom). The "frozen since" anchor for token freezes.
_now_iso() {
    command date -u +%FT%TZ
}

# _iso_to_epoch <iso> — parse an ISO-8601 Z timestamp to epoch seconds, trying
# GNU `date -d` then BSD `date -j -f` (mirrors _mtime_epoch's dual-toolchain
# approach in golem-gate-watch.sh so the frozen-duration math works on Linux and
# base macOS alike). Prints nothing on failure, so the caller falls back to
# showing the raw "frozen since <iso>" rather than a bogus minute count.
_iso_to_epoch() {
    _ie_iso="$1"
    [ -n "$_ie_iso" ] || return 0
    command date -u -d "$_ie_iso" +%s 2>/dev/null && return 0
    command date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$_ie_iso" +%s 2>/dev/null && return 0
    return 0
}

# _fmt_dur <seconds> — human-friendly "Nm" for >=60s else "Ns" (a non-negative
# second count). Matches golem-gate-watch.sh's _fmt_age wording.
_fmt_dur() {
    _fd_s="$1"
    if [ "$_fd_s" -ge 60 ]; then
        command echo "$((_fd_s / 60))m"
    else
        command echo "${_fd_s}s"
    fi
}

# render_status — emit one complete status snapshot (pool header, golem table,
# BLOCKED list, liveness, recent feed). Re-globs the cache and re-scans tmux on
# every call so --watch reflects golems that appeared/finished since the last
# sweep. Never exits the process (returns 0) so the --watch loop can re-invoke it.
render_status() {
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
        return 0
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
    # line is "golem-N alive, working ..." (pane spinner active), "golem-N ⚠ idle at
    # prompt ..." (errored/idle pane, issue #229), "golem-N alive (process up ...)"
    # (mtime heartbeat only), or "golem-N possible stall ..."; a golem at a fresh
    # gate is reported as gated here, not stalled. Never
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

    # TOP-LEVEL TOKENS (issue #371) — the mechanical frozen-counter signal feeding
    # #369's slow-review takeover contract. For each cached golem we scrape the
    # cumulative TOP-LEVEL token count from its Claude Code transcript
    # (golem-token-scrape.sh), persist it + a "frozen since" anchor back into the
    # golem's status JSON, and render how long the count has been frozen. The
    # operator reads "frozen Xm" here instead of attaching to each pane by eye.
    # This is a WORKTREE (Mode 2) signal only: a container (Mode 3) golem's
    # transcript is not host-readable, so those rows show a pending note (#390).
    # jq-gated (needs jq to read/merge the cache and sum the transcript).
    if command -v jq >/dev/null 2>&1 && [ "${#cache[@]}" -gt 0 ]; then
        command echo ""
        command echo "TOP-LEVEL TOKENS (frozen-counter signal — #369 takeover contract):"
        for f in "${cache[@]}"; do
            g="$(jq -r '.golem // "?"' "$f" 2>/dev/null)"
            ctr="$(jq -r '.container // empty' "$f" 2>/dev/null)"
            issue_n="$(jq -r '.issue // empty' "$f" 2>/dev/null)"
            # Mode 3 container golem — no host-readable transcript yet (#390).
            if [ -n "$ctr" ]; then
                command echo "  $g — n/a (container golem — token push pending, see #390)"
                continue
            fi
            # Resolve the golem's worktree and scrape its transcript. Fail-loud:
            # a missing transcript / unparsable count → "tokens unknown", never a
            # bogus frozen=0 that could trip a false takeover.
            wt="$root/$GOLEM_WORKTREE_DIR/issue-$issue_n"
            cur=""
            if [ -n "$issue_n" ] && [ -x "$scrape" ]; then
                cur="$("$scrape" "$wt" 2>/dev/null || true)"
            fi
            case "$cur" in
                '' | *[!0-9]*)
                    command echo "  $g — tokens unknown (no transcript)"
                    continue
                    ;;
            esac
            prev="$(jq -r '.top_level_tokens // empty' "$f" 2>/dev/null)"
            prev_at="$(jq -r '.top_level_tokens_at // empty' "$f" 2>/dev/null)"
            # Frozen-since bookkeeping: keep the anchor while the count is
            # unchanged; reset it to now when the count moves (or on first read).
            if [ -n "$prev" ] && [ "$cur" = "$prev" ] && [ -n "$prev_at" ]; then
                at="$prev_at"
            else
                at="$(_now_iso)"
            fi
            # Merge the two fields back into the cache JSON (atomic tempfile+mv —
            # jq cannot edit in place). Cache semantics, last-writer-wins; benign
            # against the orchestrator model's occasional writes to the same file.
            # mktemp (not a predictable "$f.tmp.$$") so a pre-planted symlink at the
            # temp path can't redirect jq's write — the tempfile lands beside $f in
            # $status_dir, keeping the mv atomic (same filesystem).
            tmp="$(command mktemp "$status_dir/.tok.XXXXXX" 2>/dev/null)"
            if [ -n "$tmp" ] && jq --argjson t "$cur" --arg at "$at" \
                '. + {top_level_tokens: $t, top_level_tokens_at: $at}' \
                "$f" >"$tmp" 2>/dev/null; then
                command mv "$tmp" "$f" 2>/dev/null || command rm -f "$tmp"
            else
                [ -n "$tmp" ] && command rm -f "$tmp"
            fi
            # Render: frozen duration if unchanged, else advancing / first reading.
            if [ -z "$prev" ]; then
                command echo "  $g — $cur tokens (first reading)"
            elif [ "$cur" != "$prev" ]; then
                command echo "  $g — $cur tokens (advancing)"
            else
                epoch="$(_iso_to_epoch "$at")"
                if [ -n "$epoch" ]; then
                    now_e="$(command date -u +%s)"
                    d=$((now_e - epoch))
                    [ "$d" -lt 0 ] && d=0
                    command echo "  $g — $cur tokens, frozen $(_fmt_dur "$d")"
                else
                    command echo "  $g — $cur tokens, frozen since $at"
                fi
            fi
        done
    fi

    if [ -f "$feed" ]; then
        command echo ""
        command echo "Recent feed ($feed):"
        /usr/bin/tail -n 10 "$feed"
    fi
}

# resolve_interval <level> — the --watch cadence in seconds, applying the
# precedence: an explicit --interval already short-circuits before this is
# called; here GOLEM_SWEEP_INTERVAL (env override) wins, else the level-scaled
# default from autonomy-resolve.sh (single source of truth for per-level
# dispositions, #190/#304). A non-numeric override or an unresolvable resolver
# value fails loud rather than silently spinning at a bogus cadence.
resolve_interval() {
    _ri_level="$1"
    if [ -n "${GOLEM_SWEEP_INTERVAL:-}" ]; then
        command printf '%s' "$GOLEM_SWEEP_INTERVAL"
        return 0
    fi
    _ri_out="$("$SCRIPT_DIR/autonomy-resolve.sh" sweep-interval --level "$_ri_level" 2>/dev/null || true)"
    _ri_secs="${_ri_out#sweep_interval_seconds=}"
    if [ -z "$_ri_secs" ] || [ "$_ri_secs" = "$_ri_out" ]; then
        command echo "golem-status: could not resolve sweep interval for level '$_ri_level'" >&2
        return 1
    fi
    command printf '%s' "$_ri_secs"
}

# is_positive_int <value> — 0 if value is a positive integer, else 1.
is_positive_int() {
    case "$1" in
        "" | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# --- drive ------------------------------------------------------------------
# Default (no args): one-shot render, exit. --watch: re-render on the resolved
# interval until the operator kills it — the orchestrator's Phase M default-on
# status sweep (#304). The loop carries no empty-poll exit (mirrors
# golem-gate-watch.sh --stream*): a transient zero-golem handoff window renders
# "No active golems" and keeps sweeping rather than terminating.
watch=0
level=1
interval=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --watch) watch=1 ;;
        --level)
            [ "$#" -ge 2 ] || {
                command echo "golem-status: --level needs a value (1-4)" >&2
                exit 2
            }
            level="$2"
            shift
            ;;
        --interval)
            [ "$#" -ge 2 ] || {
                command echo "golem-status: --interval needs a value (seconds)" >&2
                exit 2
            }
            interval="$2"
            shift
            ;;
        *)
            command echo "golem-status: unknown argument '$1' (want --watch [--level N] [--interval S])" >&2
            exit 2
            ;;
    esac
    shift
done

case "$level" in
    1 | 2 | 3 | 4) ;;
    *)
        command echo "golem-status: --level must be 1-4, got '$level'" >&2
        exit 2
        ;;
esac

if [ -n "$interval" ] && ! is_positive_int "$interval"; then
    command echo "golem-status: --interval must be a positive integer, got '$interval'" >&2
    exit 2
fi

if [ "$watch" -eq 0 ]; then
    render_status
    exit 0
fi

# --watch: resolve the cadence once (interval > env > level default), then loop.
if [ -z "$interval" ]; then
    interval="$(resolve_interval "$level")" || exit 1
fi
if ! is_positive_int "$interval"; then
    command echo "golem-status: resolved sweep interval is not a positive integer: '$interval'" >&2
    exit 2
fi

command echo "Status sweep every ${interval}s (level $level). Ctrl-C to stop." >&2
while :; do
    render_status
    command echo ""
    /usr/bin/sleep "$interval"
done
