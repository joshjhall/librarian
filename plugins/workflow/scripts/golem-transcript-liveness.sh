#!/usr/bin/env bash
# golem-transcript-liveness.sh — classify a golem as working / idle / errored by
# reading its Claude Code session transcript (TTY-free, fail-loud).
#
# Context (issue #248, fast-follow from PR #245's review of issue #229): the
# liveness sweep in golem-gate-watch.sh tells "actually working" from "idle/
# errored at the prompt" via `pane_liveness_class`, which scrapes a live
# `tmux capture-pane`. That catches the #229 failure (a dispatch batch erroring
# on line 1 and going idle while the mtime heartbeat still reads fresh) ONLY for
# a golem with a HOST-VISIBLE tmux session. A headless / CI / container-only
# golem the host tmux can't see falls straight through to the bare mtime
# heartbeat, which cannot make that distinction. This script closes that gap: it
# reads the same idle-vs-working signal from the golem's on-disk transcript, so
# the coverage matches #229's general framing rather than only the tmux-visible
# reproduction.
#
# It resolves the golem worktree's Claude Code transcript exactly as
# golem-token-scrape.sh does (`<projects>/<slug>/`, <slug> = the worktree's
# absolute path with every `/` and `.` replaced by `-`; newest-mtime `*.jsonl`),
# then classifies from STRUCTURED transcript fields — NOT a scrollback text
# scan. That structural read is what makes it immune by construction to the
# self-trip problem `pane_liveness_class` had to footer-anchor around (#246): a
# golem cat-ing/grepping a file whose text contains "Unknown command" or
# "esc to interrupt" — this very script's comments do — cannot flip the class,
# because the signal is `message.stop_reason` / `isApiErrorMessage` on the
# transcript's own assistant records, not any phrase in the conversation body.
#
# The signal — the last TOP-LEVEL (isSidechain == false) assistant record's
# `message.stop_reason`:
#   working  — stop_reason == "tool_use": a tool call is in flight right now.
#   idle     — stop_reason "end_turn"/"stop_sequence": the turn ended, so the
#              session is parked at its prompt (covers both the #229 errored-idle
#              and the #447 done-and-idle cases).
#   errored  — the idle subclass that failed: the last top-level assistant record
#              carries `isApiErrorMessage == true` ("API Error: …"), OR a
#              `type=="system"` "Unknown command" record trails the last turn
#              (the literal #229 first-command failure). Reported as idle-with-an-
#              error-hint by the caller.
# A transcript with no top-level assistant turn yet AND no command error is
# INDETERMINATE (exit 2) — the caller falls back to the mtime heartbeat rather
# than assert anything.
#
# STALENESS BOUND on `working`. A `working` verdict asserts "a tool call is in
# flight RIGHT NOW", but the transcript alone cannot prove currency: if the
# golem's Claude Code process crashes/is killed mid tool-call (OOM, container
# kill, host reboot), the last record stays frozen at `stop_reason: "tool_use"`
# and a naive read would report `working` on every future sweep — permanently
# masking the stall for the very headless population this feature targets, since
# the caller's `continue` on a positive class short-circuits the mtime stall
# check. So a `working` verdict is bounded by the transcript file's own mtime: a
# transcript untouched for longer than GOLEM_STALL_THRESHOLD seconds is treated
# as STALE and demoted to indeterminate (exit 2), handing the golem back to the
# caller's mtime heartbeat which DOES flag a stall. `idle`/`errored` are NOT
# mtime-gated — a golem legitimately parked/errored at its prompt for a long time
# is still correctly idle/errored, and that is the actionable signal.
#
# MODE 2 ONLY, same as golem-token-scrape.sh. A Mode 3 container golem runs
# Claude Code INSIDE its container, so its transcript is not on the host: slug
# resolution finds no project dir and the script exits 2 (indeterminate), and the
# caller falls back to the mtime heartbeat — no special-casing needed here.
#
# Config (env-overridable; defaults match Claude Code's on-disk layout):
#   CLAUDE_PROJECTS_DIR    Base dir holding per-project transcript dirs.
#                          Default: $HOME/.claude/projects
#   GOLEM_STALL_THRESHOLD  Seconds a transcript may sit unmodified before a
#                          `working` verdict is demoted to stale/indeterminate.
#                          Default 1200 (matches golem-gate-watch.sh's liveness
#                          stall window, so the two agree on "stalled").
#
# Usage:
#   golem-transcript-liveness.sh <worktree-dir>
#
# Output: one class word on stdout — `working`, `idle`, or `errored`. FAIL LOUD —
# the liveness sweep must never act on a bogus reading, so a missing transcript /
# missing jq / an indeterminate transcript is a non-zero exit with an actionable
# message, NOT a silent guess. The caller (golem-gate-watch.sh liveness_snapshot)
# treats any non-zero exit as "no transcript signal" and falls through to the
# mtime heartbeat — the same soft/advisory contract as the best-effort pane read.
#
# Exit status:
#   0  class written to stdout (working|idle|errored)
#   1  usage error (no worktree-dir argument)
#   2  no transcript dir / no *.jsonl session / indeterminate (no top-level turn,
#      or a `working` verdict demoted stale past GOLEM_STALL_THRESHOLD)
#   3  jq not on PATH (cannot parse the transcript)
#
# Portability: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,}); all
# coreutils reached via the `command` builtin, never a hardcoded /usr/bin path
# (issue #228/#241 — a hardcoded path exits 127 off /usr/bin). shellcheck clean.
set -uo pipefail

usage() {
    command cat >&2 <<'EOF'
usage: golem-transcript-liveness.sh <worktree-dir>

Prints the golem's liveness class (working|idle|errored) read from its Claude
Code session transcript to stdout. Exits non-zero (with a message) when the
transcript is missing/unreadable/indeterminate or jq is unavailable, so the
caller can fall back to the mtime heartbeat instead of a bogus reading.
EOF
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

worktree="$1"

if ! command -v jq >/dev/null 2>&1; then
    command echo "golem-transcript-liveness: jq not found on PATH — cannot parse transcript" >&2
    exit 3
fi

# Absolute worktree path → Claude Code project-dir slug. Claude Code names each
# project transcript dir after the absolute cwd with every `/` and `.` replaced
# by `-` (verified on-disk: /workspace/librarian/.worktrees/issue-248 →
# -workspace-librarian--worktrees-issue-248). Resolve to absolute first so a
# relative worktree arg maps to the same slug the golem's session produced. This
# resolution block is intentionally identical to golem-token-scrape.sh's — the
# two scrape the SAME transcript for different signals; keep them in sync.
case "$worktree" in
    /*) abs="$worktree" ;;
    *) abs="$(command pwd)/$worktree" ;;
esac
# Pattern substitution (`${v//[set]/repl}`) is bash-3.2 available — NOT a banned
# case-conversion (${v,,}/${v^^}); see tests/lint-shell-portability.sh.
slug="${abs//[\/.]/-}"

base="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
project_dir="$base/$slug"

if [ ! -d "$project_dir" ]; then
    command echo "golem-transcript-liveness: no transcript dir for $worktree ($project_dir)" >&2
    exit 2
fi

# Newest-mtime *.jsonl is the active session (a post-/clear session is a fresh
# file, so the newest is always the live one). `ls -t` semantics via `-nt`;
# nullglob keeps the loop empty (not a literal `*.jsonl`) when none exist.
shopt -s nullglob
newest=""
for f in "$project_dir"/*.jsonl; do
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
        newest="$f"
    fi
done

if [ -z "$newest" ]; then
    command echo "golem-transcript-liveness: no *.jsonl session transcript in $project_dir" >&2
    exit 2
fi

# Classify from the transcript's structured fields. `-R` + `fromjson?` reads
# line-by-line and skips a malformed/partial trailing line (expected when a
# session is captured mid-write), mirroring golem-token-scrape.sh; `-s` collects
# the stream so we can index by position. We locate the LAST top-level
# (isSidechain false/absent) assistant record that has a stop_reason, then:
#   - isApiErrorMessage on it            → errored
#   - stop_reason == "tool_use"          → working (a tool call is in flight)
#   - otherwise (turn ended)             → idle, promoted to errored if a
#                                          "Unknown command" system record trails
#                                          the last turn (#229 first-command fail)
# With NO top-level turn yet: a trailing "Unknown command" is the #229 line-1
# failure (errored); anything else is indeterminate ("unknown" → exit 2).
class="$(
    jq -R -s -r '
      [ split("\n")[] | select(length > 0) | (fromjson? // empty) ] as $recs
      | [ $recs | to_entries[]
          | select(.value.type == "assistant"
                   and ((.value.isSidechain // false) == false)
                   and (.value.message.stop_reason != null)) ] as $asst
      | if ($asst | length) == 0 then
          ( [ $recs[]
              | select(.type == "system"
                       and ((.content // "") | test("Unknown command"))) ]
            | length ) as $unk
          | if $unk > 0 then "errored" else "unknown" end
        else
          ($asst[-1]) as $last
          | if (($last.value.isApiErrorMessage // false) == true) then "errored"
            elif ($last.value.message.stop_reason == "tool_use") then "working"
            else
              ( [ $recs | to_entries[]
                  | select(.key > $last.key
                           and .value.type == "system"
                           and ((.value.content // "") | test("Unknown command"))) ]
                | length ) as $unk
              | if $unk > 0 then "errored" else "idle" end
            end
        end
    ' "$newest" 2>/dev/null
)"

# Newest transcript mtime in epoch seconds (GNU `stat -c %Y` then BSD `stat -f
# %m`, mirroring golem-gate-watch.sh's _mtime_epoch). Empty if it cannot stat —
# in which case the staleness guard below is skipped (fail-open on the guard, not
# on the verdict) rather than demoting a possibly-live `working` on a stat quirk.
_newest_mtime="$(command stat -c %Y "$newest" 2>/dev/null ||
    command stat -f %m "$newest" 2>/dev/null || true)"
stall_threshold="${GOLEM_STALL_THRESHOLD:-1200}"

case "$class" in
    working)
        # Staleness bound (see header): a `working` verdict is only trustworthy if
        # the transcript is still being written. If it has sat unmodified past the
        # stall threshold, the golem's process likely died mid tool-call and the
        # `tool_use` line is frozen — demote to indeterminate so the caller's mtime
        # heartbeat regains stall detection. Skip the guard only when the mtime is
        # unreadable (then trust the class rather than a failed stat).
        case "$_newest_mtime" in
            '' | *[!0-9]*) command printf '%s\n' "working" ;;
            *)
                _now="$(command date +%s)"
                _age=$((_now - _newest_mtime))
                [ "$_age" -lt 0 ] && _age=0
                if [ "$_age" -gt "$stall_threshold" ]; then
                    command echo "golem-transcript-liveness: stale 'working' transcript (${_age}s > ${stall_threshold}s) in $newest" >&2
                    exit 2
                fi
                command printf '%s\n' "working"
                ;;
        esac
        ;;
    idle | errored)
        # Not mtime-gated: a long-idle/errored golem is still correctly idle/errored.
        command printf '%s\n' "$class"
        ;;
    *)
        # "unknown" (no top-level turn, no error) or an empty/failed parse:
        # indeterminate — the caller falls back to the mtime heartbeat.
        command echo "golem-transcript-liveness: indeterminate transcript (no top-level turn) in $newest" >&2
        exit 2
        ;;
esac
