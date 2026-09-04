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
#           (golem-notify.sh) and classified `gate` vs `idle` vs `escalation` vs
#           `dead-end`. TTY-free, works for ALL golems incl. headless/container,
#           carries golem-id attribution. A plan-gate `ExitPlanMode` shows only as
#           a generic `gate` here; a mid-flight `escalation` (issue #176) and a
#           `dead-end` (issue #180) surface in the same BLOCKED set but are
#           labelled distinctly ("escalation — …" / "dead-end — …").
#   panes — `tmux capture-pane` on live `golem-*` sessions, matched against the
#           modal PROMPT OVERLAY ("Do you want to proceed?" / the ExitPlanMode
#           plan prompt / an AskUserQuestion escalation fork's `Enter to select`
#           footer — #257). The "capture-pane is blank until exit" caveat applies
#           to scrolling WORK OUTPUT, not the prompt overlay, which renders over
#           the alt-screen and is reliably scrapeable — and is the better
#           catcher of plan-gate prompts. A fork is the last-resort match (after
#           plan-gate and generic-gate) and is emitted as a distinct
#           "escalation — …" line so the operator knows it carries options. A
#           MULTI-QUESTION form (#467) is a strictly more specific fork and is
#           matched just BEFORE it, emitting a line that names the keystroke
#           rule that widget needs (forward-order, never a digit). Live
#           worktree golems only.
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
#   "golem-N alive (process up, last activity Ns ago)" (mtime within
#     GOLEM_STALL_THRESHOLD), or
#   "golem-N: possible stall — no progress for Nm" (older).
# The mtime heartbeat proves only that the PROCESS/worktree is live, NOT that
# work is happening — right after launch those mtimes are fresh even if the
# session errored on line 1 and went idle at its prompt (issue #229). So the
# sweep tries two stronger reads before the mtime proxy, in order:
#   1. pane (tmux) — when a live golem-* pane is scrapeable, `pane_liveness_class`
#      reads "alive, working" from the `esc to interrupt` run-spinner in the
#      footer, "⚠ died — API error" on the #446 death signature (an `API Error`
#      4xx/5xx in the scrollback with no spinner — a golem whose process died on a
#      transient/terminal API error and parked at its prompt looking exactly like
#      a finished turn), or "⚠ idle at prompt" on an error/idle signature. The
#      match is anchored to the pane's FOOTER region (the last GOLEM_PANE_FOOTER_LINES
#      lines, where the spinner/input-box/footer chrome renders) rather than the
#      whole scrollback, so a golem cat-ing/grepping a file whose text happens to
#      contain those trigger phrases — this very script does — does not self-trip
#      the classifier (issue #246).
#   2. transcript (issue #248) — when the pane read does not classify (a
#      headless / CI / container-only golem the host tmux CANNOT see, or an
#      indeterminate pane), `golem-transcript-liveness.sh` reads the same
#      working/idle/errored signal from the golem's on-disk Claude Code transcript
#      (`message.stop_reason` / `isApiErrorMessage` on its top-level assistant
#      records — structured fields, so immune by construction to the scrollback
#      self-trip the pane tier had to footer-anchor around). This extends the #229
#      idle/errored detection to the headless population the pane tier misses.
# Both stronger reads are best-effort — a golem with no host-visible pane AND no
# host-readable transcript (e.g. a Mode-3 container golem) falls back to the
# reworded mtime heartbeat.
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
#                            gate, died on an API error (#446), OR turn-ended/idle
#                            at their prompt (#447)
#   --stream-panes           pane poll loop: emit on transition, until killed
#   --once-liveness          liveness snapshot: per-golem heartbeat/stall, exit 0
#   --stream-liveness        liveness poll loop: emit on a per-golem class change
#                            (working→idle, alive→stall, →gated), deduped like the
#                            gate channels, plus a slow aggregate "N alive …"
#                            summary every GOLEM_LIVENESS_SUMMARY_INTERVAL; polls
#                            every GOLEM_HEARTBEAT_INTERVAL, until killed (#489)
#
# Tunables (env; see config.sh for worktree/status-dir tunables):
#   GOLEM_BLOCK_TTL          feed gate freshness window, seconds (default 3600)
#   GOLEM_WATCH_INTERVAL     poll interval for --stream*, seconds (default 5)
#   GOLEM_STALL_THRESHOLD    liveness stall window, seconds (default 1200)
#   GOLEM_HEARTBEAT_INTERVAL liveness poll interval, seconds (default 60)
#   GOLEM_LIVENESS_SUMMARY_INTERVAL
#                            --stream-liveness aggregate-summary cadence, seconds
#                            (default 900; 0 disables the summary) (#489)
#   GOLEM_PANE_FOOTER_LINES  pane footer window for pane_liveness_class +
#                            pane_is_fork, lines (default 8)
#   GOLEM_PANE_ERROR_LINES   pane scrollback window for pane_is_api_error's #446
#                            death read, lines (default 40)
#
# Never blocks a golem and never hangs on a missing feed/tmux: errors are
# swallowed and a snapshot mode always exits 0. The `--stream*` loops carry NO
# "zero golems remain -> stop" exit: a transient zero-golem window (the handoff
# beat where one golem's session is killed and the next is created) never
# terminates the watch; it stops only when the operator/harness kills it.
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# This script runs under a potentially stripped/hermetic PATH (its liveness /
# --watch paths are tested with PATH reduced to a few stubs), so `command <tool>`
# would fail to find an external core utility there — yet a hardcoded /usr/bin/<tool>
# is wrong on macOS. `_bin <tool>` honors PATH first (the `command -v` builtin
# needs no external binary), then falls back to scanning the standard bin dirs so
# it still resolves under a stripped PATH, then yields the bare name. Candidates
# are bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint does not
# flag them. Defined before SCRIPT_DIR so even that resolution is portable.
_BIN_CANDIDATE_DIRS="/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin"
_bin() {
    _br="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$_br" ]; then
        for _bd in $_BIN_CANDIDATE_DIRS; do
            [ -x "$_bd/$1" ] && {
                _br="$_bd/$1"
                break
            }
        done
    fi
    printf '%s' "${_br:-$1}"
}
DATE="$(_bin date)"
DIRNAME="$(_bin dirname)"
GREP="$(_bin grep)"
HEAD="$(_bin head)"
SLEEP="$(_bin sleep)"
SORT="$(_bin sort)"
STAT="$(_bin stat)"
TAIL="$(_bin tail)"
TR="$(_bin tr)"

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"
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
# Coerce a non-numeric GOLEM_HEARTBEAT_INTERVAL (a plausible typo like "15m") back
# to the default: it feeds the --stream-liveness cadence arithmetic below, and a
# bare alphabetic token in `$(( ))` aborts the whole watch under `set -u` (#489
# review). Fail-soft to 60, consistent with this script's "errors are swallowed,
# never fail a golem" contract and summary_due's own numeric guard.
case "$heartbeat_interval" in
    '' | *[!0-9]*) heartbeat_interval=60 ;;
esac
# Cadence of the slow aggregate liveness summary on --stream-liveness (issue
# #489), seconds; 0 disables it. The per-golem heartbeat is now transition-
# deduped, so this one-line-per-fleet summary is the only periodic positive
# "watch is alive" signal — paced far slower than the poll interval.
summary_interval="${GOLEM_LIVENESS_SUMMARY_INTERVAL:-900}"
pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"
# Window for the #446 API-error death read. The `API Error` line sits a few lines
# ABOVE the prompt (the issue used `capture-pane -S -40`), outside the 8-line
# footer the gate/turn-end matchers anchor to — so pane_is_api_error scans a wider
# tail. Separate tunable so widening it does not loosen the footer matchers.
pane_error_lines="${GOLEM_PANE_ERROR_LINES:-40}"

# The turn-end/idle-at-prompt push message (#447). Defined once here because two
# functions couple on it: panes_snapshot() emits it, and confirm_turn_end()
# recognizes it to apply the two-consecutive-poll debounce (below). A top-level
# assignment so a SOURCED unit test sees it before calling either function.
TURN_END_MSG="⚠ idle at prompt — turn ended, awaiting input (check pane)"

# The multi-question-form push message (#467). It states the KEYSTROKE RULE
# rather than just the gate class, because the observed operator error was
# applying the single-question reflex (`1 Enter`) to a widget where a digit does
# nothing or hits the wrong question — and where the review screen will submit a
# partially-answered form. Forward-order + never-a-digit are the two constraints
# that keep a broker out of that failure, so the label carries them: it is the
# one place the correction reliably reaches the operator, and it says what to do
# rather than merely what happened. (The full protocol, including the
# cancel-then-relay fallback for revising an earlier answer, is
# orchestrate/monitor-protocol.md § "A multi-question form is brokered
# differently".) Defined beside TURN_END_MSG so a SOURCED unit test sees it.
MULTI_Q_MSG="escalation (multi-question form) — forward-order only, never a digit"

# The API-error death push message (#446). A golem whose `claude` process died on
# a transient API error (429/5xx) or a terminal one (auth/quota) goes idle at the
# `⏵⏵ auto mode on` prompt — byte-identical to a finished turn — with no feed
# event, gate, or signal, so it reads as idle-complete and an orchestrator either
# tears it down (losing durable work) or parks it forever. panes_snapshot() reads
# the pane scrollback (the ONLY ground-truth signal — a dead process can't emit
# its own feed line) and emits this instead. The `%s` is filled with a
# retriable/terminal classification so an orchestrator can auto-resume a transient
# death vs escalate a terminal one.
DIED_MSG_PREFIX="⚠ died — API error"

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
# legacy `blocked`, a mid-flight `escalation`, or a `dead-end`) within the
# freshness window — identical semantics to the golem-status.sh BLOCKED list
# (kept in lockstep so the two never drift). An `escalation` line is labelled
# "escalation — <message>" and a `dead-end` line "dead-end — <message>" so the
# reader can tell a judgement call (and the L4-blocking dead-end) apart from a
# routine permission gate.
#
# The orphan sentinel `golem-?` is dropped BEFORE the event/TTL predicate (issue
# #323): golem-notify.sh stamps a feed line `golem-?` when the Notification fires
# from a session with no GOLEM_ID, no AGENT_ID, and no worktree root (the
# orchestrator's own session, a plain `claude` in the main checkout). No real
# golem ever carries that id, so no future `idle` supersedes it, and a no-`ts`
# line bypasses the TTL by design (#24) — so an orphan `golem-?` gate would stay
# BLOCKED forever. It is never actionable anyway (`golem-?` has no golem-attach
# target), so it is never surfaced as a block.
#
# A CONTAINER golem is deliberately NOT covered by this drop (#744): since
# golem-notify.sh grew an `$AGENT_ID` rung, such a session keys the feed on its
# own `agentNN` rather than falling through to `golem-?`. That is the point of
# the rung — an `agentNN` gate is a REAL block that must surface under its own
# row, so it is screened by the liveness cross-check (`golem_has_live_trace`)
# like any other golem, not silently discarded here. A future reader wondering
# why an `agentNN` gate is not dropped should start there, not at this predicate.
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
    #
    # The type/emptiness guard screens null/"" but NOT a non-empty string that
    # fails `fromdateiso8601`'s strict `%Y-%m-%dT%H:%M:%SZ` parse (e.g. a truncated
    # or garbage `ts` from a partial write / an untrusted external POST). That
    # parse abort is program-wide — one malformed line blanks the ENTIRE snapshot
    # for EVERY golem, not just its own (the exact #24 blast radius the empty guard
    # was meant to close, re-entered through a different door). So wrap the parse in
    # `try … catch true`: a line whose `ts` cannot be parsed degrades to the same
    # TTL-bypass "fresh" fallback as a no-`ts` line — surfaced, and localized to
    # itself — instead of aborting the whole jq program (#432).
    "$TAIL" -n 200 "$feed" 2>/dev/null |
        jq -rs --argjson ttl "$ttl" '
            (now) as $now
            | group_by(.golem)
            | map(.[-1])
            | map(select(.golem != "golem-?"))
            | map(select((.event == "gate" or .event == "blocked" or .event == "escalation" or .event == "dead-end")
                         and (if (.ts | type) == "string" and .ts != ""
                              then (try (($now - (.ts | fromdateiso8601)) < $ttl) catch true)
                              else true end)))
            | .[]
            | (.message // "awaiting decision") as $m
            | if .event == "dead-end" then "\(.golem)\tdead-end — \($m)"
              elif .event == "escalation" then "\(.golem)\tescalation — \($m)"
              else "\(.golem)\t\($m)" end
          ' 2>/dev/null |
        "$SORT" -u
}

# golem_has_live_trace <golem-id> — true when ANY on-disk/tmux trace of the golem
# still exists: a live `golem-N` tmux session, an `issue-N` worktree dir, or a
# `golem-N.json` / `issue-N.json` status-cache file. Defense-in-depth for #446's
# ghost bug: a golem torn down WITHOUT worktree-rm.sh (killed by hand, or a stale
# pre-existing feed line) emits no terminal `reaped` line, so its last `gate`
# stays its most-recent feed entry and renders BLOCKED for the whole
# GOLEM_BLOCK_TTL window even though nothing of it remains. The primary fix is the
# `reaped` line worktree-rm.sh emits (superseding the gate); this reader-side
# check covers the teardown paths that emit no line.
#
# The probes mirror liveness_snapshot's own union-of-sources (tmux ls + status
# cache glob + worktree dir), so the two liveness reads stay consistent. The
# predicate is a conservative OR: a golem with a cache file but no host-visible
# tmux session (a headless/container golem) still has a trace and is KEPT — its
# gate may be real. Only a golem with ZERO traces is dropped. bash-3.2 clean.
# Requires the golem id already normalized to `golem-N`; extracts N internally.
golem_has_live_trace() {
    local golem="$1" n status_dir root
    # 1. Live tmux session — the session name IS the golem id, so this works for
    #    any id shape (numeric or otherwise).
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$golem" 2>/dev/null; then
        return 0
    fi
    status_dir="$(resolve_status_dir 2>/dev/null || true)"
    # 2. Status-cache file keyed by the full golem id (`golem-N.json`) — the real
    #    cache naming, and the trace a headless/container golem carries with no
    #    host-visible tmux session. Keyed by the whole id so it is id-shape-agnostic.
    if [ -n "$status_dir" ]; then
        [ -e "$status_dir/$golem.json" ] && return 0
    fi
    # 3. Numeric-derived probes: the `issue-N.json` cache alias and the on-disk
    #    worktree dir. Only a well-formed `golem-N` has these; a non-numeric id
    #    (e.g. the `golem-?` sentinel, already dropped upstream in feed_snapshot)
    #    has no further trace to probe and falls through to no-trace.
    n="${golem#golem-}"
    case "$n" in
        '' | *[!0-9]*) return 1 ;;
    esac
    if [ -n "$status_dir" ]; then
        [ -e "$status_dir/issue-$n.json" ] && return 0
    fi
    root="$(repo_root 2>/dev/null || true)"
    if [ -n "$root" ] && [ -d "$root/$GOLEM_WORKTREE_DIR/issue-$n" ]; then
        return 0
    fi
    return 1
}

# feed_snapshot_live <feed> — feed_snapshot filtered through golem_has_live_trace,
# so a gated golem with no on-disk/tmux trace left (a ghost, #446) is dropped from
# the BLOCKED set. This is the form the `--once` / `--stream` drive paths use
# (and, through the `--once` delegation, golem-status.sh's BLOCKED list) so the
# ghost filter applies wherever a golem is surfaced as blocked. feed_snapshot
# itself stays PURE (unfiltered) so the unit tests can assert the raw feed
# semantics (TTL, event-kind, orphan-drop) in isolation without standing up a
# worktree/session for every fixture golem.
feed_snapshot_live() {
    local feed="$1" g msg
    feed_snapshot "$feed" |
        while IFS=$'\t' read -r g msg; do
            [ -n "$g" ] || continue
            if golem_has_live_trace "$g"; then
                command printf '%s\t%s\n' "$g" "$msg"
            fi
        done
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
            [ "$prime" = "1" ] || command printf '%s\t%s\n' "$golem" "$msg"
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
# Modal prompt-overlay patterns. A live golem at a permission/plan gate — or an
# AskUserQuestion escalation fork (#257) — paints one of these over its
# alt-screen; matching them is reliable (unlike scraping scrolling work output).
# Extend these lists as new prompt shapes appear. pane_is_turn_end (#447) is the
# odd one out — NOT a modal overlay but a turn-ended/idle-at-prompt footer read —
# and so runs as panes_snapshot's LAST-RESORT branch, after all three modals.
#
# Like pane_is_fork and pane_liveness_class, both matchers are ANCHORED to the
# pane's FOOTER region (last $pane_footer_lines lines, where a modal overlay
# renders) — NOT the whole scrollback — the #246 protection (#452). The trigger
# phrases (`Here is Claude's plan`, `Do you want to proceed`, …) appear in this
# script's own comments, in tests/golem-gate-watch.sh, and in golem work output;
# a golem editing/`cat`-ing such a file would otherwise self-trip a false
# plan/permission gate push.
pane_is_plan_gate() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Ready to code"*) return 0 ;;
        *"ready to code"*) return 0 ;;
        *"Would you like to proceed"*) return 0 ;;
        *"Here is Claude's plan"*) return 0 ;;
        *"Yes, and use auto mode"*) return 0 ;;
    esac
    return 1
}

# Generic permission-decision overlay (Bash/Edit/push/PR `ask` rules etc.).
# Footer-anchored for the same #246/#452 reason as pane_is_plan_gate above.
pane_is_gate() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Do you want to proceed"*) return 0 ;;
    esac
    return 1
}

# AskUserQuestion escalation-fork overlay (issue #257). A golem parked at a
# numbered architectural/scoping decision — an ESCALATION gate per
# `orchestrate/autonomy-levels.md`, human at L1–L3 — paints a selection modal
# whose stable signature is the footer line `Enter to select` (rendered with
# `↑/↓ to navigate` / `Tab/Arrow keys to navigate`). This overlay matches
# neither pane_is_plan_gate nor pane_is_gate, so before this matcher a fork was
# silently missed by the pane channel.
#
# `Enter to select` is the generic Claude Code selection-modal footer, not unique
# to AskUserQuestion, so this is a BEST-EFFORT label of last resort: run only
# AFTER the plan-gate and generic-gate matchers, it names an overlay they didn't
# recognize an "escalation" on the assumption it is a fork. That is right for a
# real AskUserQuestion fork and errs toward surfacing (an unrecognized overlay is
# reported rather than dropped); the tradeoff is that a plan/permission overlay
# whose exact wording drifts out of those matchers could surface here mislabelled
# rather than silently missed. Two guards keep the footer phrase from
# over-matching:
#   1. panes_snapshot() checks pane_is_plan_gate AND pane_is_gate FIRST — the
#      fork is the last-resort branch, so a plan overlay (which may share the
#      `Yes, and use auto mode` line and an `Enter to select` footer) or a
#      routine permission gate (whose own selection menu may paint the same
#      footer) is classified as itself, never downgraded to an escalation.
#   2. The match is ANCHORED to the pane's FOOTER region (last $pane_footer_lines
#      lines, where the modal footer renders) — NOT the whole scrollback — the
#      same protection pane_liveness_class uses for #246. `Enter to select` now
#      appears in this script's own comments and in tests/golem-gate-watch.sh, so
#      a golem cat-ing/grepping those files would otherwise self-trip the matcher
#      into a false `escalation` notification.
pane_is_fork() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Enter to select"*) return 0 ;;
    esac
    return 1
}

# Multi-question AskUserQuestion form (issue #467). A golem raising 2+ questions
# in ONE prompt paints a TABBED widget — a per-question tab bar with `☐`/`☒`
# checkboxes and a trailing `✔ Submit` tab — over the same `Enter to select`
# footer a single-question fork paints. It is therefore a strictly MORE SPECIFIC
# fork, and panes_snapshot() runs it BEFORE pane_is_fork so the general branch
# cannot shadow it (the same precedence discipline plan-gate/generic-gate already
# use, and the same reason pane_is_api_error runs before pane_is_turn_end).
#
# WHY IT EARNS ITS OWN CLASS. This widget takes DIFFERENT keystrokes from the
# single-question prompt, and the documented brokers fail on it in ways that
# RESOLVE THE GATE WRONG rather than merely failing:
#   - The plan-gate broker (`tmux send-keys -t golem-{N} 1 Enter`) assumes one
#     question. Observed live: a digit did nothing in one incident and landed on
#     the WRONG question in another (the widget needs `↑/↓`+`Enter`), and after
#     an out-of-order answer `Tab` cycled between the answered question and the
#     Submit screen without ever reaching the still-`☐` one. The review screen
#     then offered `Submit` with a question unanswered — one stray Enter submits
#     a HALF-ANSWERED form the golem acts on as the operator's decision.
#   - The inbox broker (`golem-inbox.sh answer <golem> <gate-id> <option>`)
#     carries ONE option per gate-id; a form has no single answer. (And a
#     plan-time fork is not inbox-routed at all — the data-only invariant, #227.)
# A form IS brokerable — answer forward-order with `↑/↓`+`Enter` and submit only
# at all-`☒`, falling back to cancel-then-text-directive when an earlier answer
# needs revising (orchestrate/monitor-protocol.md). But since the keystrokes
# differ by widget, a broker must BRANCH on single-vs-multi, and that branch is
# what this matcher exists to enable — see the message const above.
#
# DETECTION FAILED BEFORE KEYSTROKES DID — the reason this is not footer-anchored
# like its siblings. The `☐/☒` tab bar renders ABOVE the footer, and in a live
# incident the first capture-pane showed only ONE of a form's TWO questions (the
# second had scrolled out of view), so an orchestrator reading the footer alone
# would broker a two-question form believing it single. So this matcher follows
# the pane_is_api_error shape instead: a footer-anchored VETO plus a wider
# content scan. It deliberately reuses $pane_error_lines rather than adding a
# knob — a new env var would need a README env-table row and would otherwise
# trip tests/lint-env-var-drift.sh.
#
# TWO SIGNALS ARE REQUIRED, and neither alone is sufficient:
#   footer `Enter to select` — without it this is not a selection modal at all;
#   a widget glyph in the wider window — without it this is the ORDINARY
#   single-question fork that pane_is_fork already handles.
#
# THE GLYPH SIGNAL IS LINE-ANCHORED, and that is load-bearing rather than
# cosmetic. The two signals are independent substring tests over different
# windows, so nothing ties the glyph to the widget that painted the footer: with
# a bare `☐|☒|✔ Submit` scan, an ORDINARY single-question fork preceded within 40
# lines by unrelated text containing a checkbox misclassifies as a form. That is
# not hypothetical — the prose describing this very feature
# (escalation-protocol.md, monitor-protocol.md, this comment block, and the test
# fixtures) all contain those glyphs literally, so a golem reading any of them
# while at a normal fork would self-trip. A conjunction of two independently
# satisfiable signals is not a self-trip guard, however it is described.
#
# What separates them is SHAPE, not vocabulary: a real tab bar is its own short
# line STARTING with a checkbox (optionally behind the `←` scroll arrow), while
# prose carries the same glyphs mid-sentence. Anchoring to the line start rejects
# every prose form above while still matching the live widget — and the
# unanswered-questions warning gets the same treatment for the same reason.
# The `esc to interrupt` veto runs first as a further guard: a golem actively
# WORKING is never at a gate, whatever its scrollback holds.
MULTI_Q_RE='^[[:space:]]*(←[[:space:]]*)?(☐|☒)|^[[:space:]]*⚠[^`]*not answered all'
pane_is_multi_question_form() {
    local pane="$1" footer window
    # Guard 1 (footer-anchored): an active run-spinner means the golem is working.
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$pane")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # Guard 2 (footer-anchored): it must be a selection modal.
    case "$footer" in
        *"Enter to select"*) ;;
        *) return 1 ;;
    esac
    # Guard 3 (wider window): the tab bar that makes it MULTI-question. Scanned
    # over $pane_error_lines because it renders above the footer — the scrolled-
    # out-of-view case that motivated this matcher.
    window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    command printf '%s\n' "$window" | "$GREP" -qE "$MULTI_Q_RE"
}

# Own-work-pending guard for pane_is_turn_end / pane_liveness_class (issue #517). A
# golem parked BETWEEN turns waiting on its OWN background `Monitor` tasks — e.g.
# ship-issue's review-harness dynamic workflow plus a CI/force-push Monitor — has
# no `esc to interrupt` run-spinner (its turn technically ended; the monitors are
# what it awaits), so the idle-footer heuristic alone would classify it "idle at
# prompt awaiting input" and false-fire the #447 push (and the #38 liveness idle
# read). But it is NOT awaiting a human — it has a queued next action gated only on
# its own monitors. This predicate returns 0 when the footer advertises that
# pending own-work, so the caller can exclude it. The two-poll debounce
# (confirm_turn_end) does NOT separate this from a real idle: the footer holds this
# shape across many polls while the monitors run, confirming the false idle — the
# matcher itself must exclude.
#
# Matched with `grep -E` per line (NOT a bash case-glob): case-globs can't express a
# word boundary and match across embedded newlines, so an unanchored `*[0-9]
# monitor*` fires on prose like "Filed 3 monitor-related bugs" and an unbounded
# `*[0-9]/[0-9]*" agents done"*` matches a digit on one line and "agents done" on
# another (issue #517 cycle-2 review). Each signature is anchored to a STRONG,
# chrome-specific LEAD-IN — a footer glyph or a fixed phrase, never a lone digit or a
# bare comma — so ordinary completion prose that merely mentions these words does NOT
# suppress a genuine idle (that would itself be the #517 false-negative):
#   `· N monitor(s)` OR `N shell, N monitor(s)`  the real monitor-count footer chrome
#                               — the count must follow the `·` bullet separator or
#                               the `N shell,` token, NOT any comma (cycle-3 review:
#                               a bare comma matches ordinary prose like "he noted, 4
#                               monitors flagged"). Covers `N monitor still running`
#                               and the `N monitors` plural.
#   `Waiting for … dynamic workflow` / `Waiting for … to finish`  the in-flight wait
#                               lines (ship-issue's review workflow and the CI/force-
#                               push Monitor). Anchored on the `Waiting for` prefix
#                               (the real signal), which also rules out prose like
#                               "the dynamic workflow finished" that has no prefix —
#                               and covers the issue's second `*to finish*` body
#                               pattern (e.g. "Waiting for the force-push … to finish").
#   `N/M agents done`           the `next-issue-review … N/M agents done` harness
#                               footer (fraction immediately before the phrase).
# Same FOOTER anchoring as the sibling matchers (#246) — reuses the
# $pane_footer_lines window, no wider scan. This is the shared #517 chrome list;
# both the push matcher (pane_is_turn_end) and the pull classifier
# (pane_liveness_class) call it so their idle reads stay consistent.
OWN_WORK_RE='(·[[:space:]]*|[0-9]+[[:space:]]+shells?,[[:space:]]*)[0-9]+[[:space:]]+monitors?([[:space:]]|$)'
OWN_WORK_RE="${OWN_WORK_RE}|[Ww]aiting for.*dynamic workflow"
OWN_WORK_RE="${OWN_WORK_RE}|[Ww]aiting for.*to finish"
OWN_WORK_RE="${OWN_WORK_RE}|[0-9]+/[0-9]+[[:space:]]+agents[[:space:]]+done"
pane_pending_own_work() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    command printf '%s\n' "$footer" | "$GREP" -qE "$OWN_WORK_RE"
}

# Turn-ended / idle-at-prompt overlay (issue #447). NOT a modal overlay: a golem
# that finished its turn and sits at an empty prompt awaiting human input — e.g.
# commit signing halted on a locked 1Password vault, so the golem correctly
# stopped rather than spin — paints only the ordinary `⏵⏵ auto mode on` footer
# with no `esc to interrupt` run-spinner above it. The other three matchers detect
# a MODAL prompt (plan/permission/fork), so this stall class slips past every push
# channel — the exact hours-costing gap #447 describes. This matcher mirrors the
# GLYPH arm of pane_liveness_class (the auto-mode-on footer with no spinner) — NOT
# its `Unknown command` arm: that #229 error signature stays pull-only on the
# liveness channel; the push channel deliberately reports only the turn-ended-at-
# prompt footer here. So the pane push channel emits it too, letting it flow
# through emit_transitions' dedup (fired once on the transition into the idle
# state, re-fired only after it clears) — the turn-ended signal belongs on the
# edge-triggered pane push channel, not the periodic liveness heartbeat.
#
# Same two guards as pane_liveness_class (see #246): the match is ANCHORED to the
# FOOTER region (last $pane_footer_lines lines) — this very script's comments carry
# `auto mode on` and `esc to interrupt`, so a whole-scrollback match would
# self-trip — and it requires the `⏵⏵` box-drawing glyph so a bare-words mention
# stays unmatched. The run-spinner is checked FIRST: a working golem still paints
# the `auto mode on` footer, so `esc to interrupt` present ⇒ NOT idle.
#
# This is a SINGLE-poll match. The two-consecutive-poll confirmation the issue
# asks for — so a momentary between-turns render does not fire a false idle — is
# layered on top in the --stream-panes drive arm via confirm_turn_end(), NOT here,
# so --once-panes and the unit tests can assert the raw matcher in isolation.
#
# A second guard (issue #517) sits between the spinner check and the positive
# footer match: pane_pending_own_work returns 0 when the golem is parked on its OWN
# background monitors / a running dynamic workflow / the review harness — alive
# with a queued next action, NOT awaiting a human — so that legitimate between-turns
# park does not false-fire the idle push (the debounce cannot separate it; see
# pane_pending_own_work). Only when the spinner is absent AND no own-work is pending
# is the golem genuinely idle-at-prompt awaiting a human (the #447 target case).
pane_is_turn_end() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # #517: parked on its own monitors / dynamic workflow / review harness ⇒ not a
    # human-awaiting idle, even though the run-spinner is absent.
    if pane_pending_own_work "$1"; then
        return 1
    fi
    case "$footer" in
        *"⏵⏵"*"auto mode on"*) return 0 ;;
    esac
    return 1
}

# API-error death read (issue #446). A golem whose `claude` process died on a
# transient API error (429/5xx) or a terminal one (auth/quota) stops and sits at
# the ordinary `⏵⏵ auto mode on` prompt — indistinguishable from a finished turn
# by the footer alone — while the error line (`API Error: ...`) sits a few lines
# ABOVE, in the scrollback. So unlike the gate/turn-end matchers this scans the
# wider `$pane_error_lines` tail, not just the 8-line footer, to catch the error
# line. Best-effort, like pane_is_turn_end / the #229 idle read.
#
# Two guards keep it from over-matching (same discipline as pane_liveness_class,
# #246): (1) a live golem still WORKING (spinner up) is never a death — if the
# FOOTER carries `esc to interrupt`, return no-match regardless of scrollback, so
# a golem reading an old error in its own transcript while actively working does
# not self-trip. (2) The signature is the specific Claude Code `API Error` string
# followed by a status code, not a bare word, so a golem discussing "api error"
# in prose stays unmatched. panes_snapshot() also runs this BEFORE pane_is_turn_end
# so a died pane (which also paints the bare turn-end footer) is classified as the
# more-specific death, never downgraded to turn-end.
pane_is_api_error() {
    local pane="$1" footer window
    # Guard 1: an active run-spinner in the footer means the process is alive and
    # working — never a death, whatever the scrollback holds.
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$pane")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # Guard 2: the specific `API Error` signature with a status code, scanned over
    # the wider death window. grep -E over the tail (not a bash glob) so the digit
    # class is exact; anchored to `API Error` immediately preceding the code.
    window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    if command printf '%s\n' "$window" |
        "$GREP" -qE 'API Error[^0-9]*(4[0-9][0-9]|5[0-9][0-9])'; then
        return 0
    fi
    return 1
}

# Classify a died pane's API error as retriable (transient — auto-resume
# candidate) or terminal (auth/quota — needs a human), for the emitted message.
# 429 and 5xx are transient; 401/403 (auth) and 402 (quota/billing) are terminal;
# any other 4xx defaults to terminal (conservative — surface for a human rather
# than auto-resume into a wall). Prints "retriable (NNN)" or "terminal (NNN)";
# "unknown" when no code is found (shouldn't happen — pane_is_api_error matched a
# code — but never emit a bare classification).
pane_api_error_class() {
    local pane="$1" window code
    window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    code="$(command printf '%s\n' "$window" |
        "$GREP" -oE 'API Error[^0-9]*(4[0-9][0-9]|5[0-9][0-9])' |
        "$GREP" -oE '(4[0-9][0-9]|5[0-9][0-9])' | "$HEAD" -n1)"
    case "$code" in
        429 | 5??) command echo "retriable ($code)" ;;
        '') command echo "unknown" ;;
        *) command echo "terminal ($code)" ;;
    esac
}

# Print the current set of live golem-* sessions sitting at a prompt overlay,
# one "<golem>\t<message>" line each. No-op (success) when tmux is absent.
#
# Dispatch order is load-bearing: plan-gate → permission-gate → multi-question
# form → escalation fork → turn-end. Each modal matcher is checked before
# pane_is_turn_end so a real overlay is classified as itself, never downgraded to
# the last-resort idle read (a modal prompt still renders the `auto mode on`
# footer underneath it). This is the same precedence discipline the fork branch
# already relies on.
#
# The multi-question form (#467) sits immediately BEFORE the fork for that same
# reason, and the order is the whole point of the branch: a form paints the fork's
# `Enter to select` footer too, so with the two swapped pane_is_fork would match
# first and every form would be labelled a plain "escalation" — sending the
# operator to the single-question brokers that resolve it WRONG (a partial
# submit). A unit rc check cannot catch that regression; the end-to-end dispatch
# test in tests/gate-watch/30-helpers-and-modes.sh is what pins it.
panes_snapshot() {
    command -v tmux >/dev/null 2>&1 || return 0
    local sessions sess pane
    sessions="$(tmux ls 2>/dev/null | "$GREP" -oE '^golem-[0-9]+' || true)"
    [ -z "$sessions" ] && return 0
    for sess in $sessions; do
        pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null || true)"
        [ -z "$pane" ] && continue
        if pane_is_plan_gate "$pane"; then
            command printf '%s\t%s\n' "$sess" "plan gate — ExitPlanMode awaiting approval"
        elif pane_is_gate "$pane"; then
            command printf '%s\t%s\n' "$sess" "permission gate — awaiting decision"
        elif pane_is_multi_question_form "$pane"; then
            command printf '%s\t%s\n' "$sess" "$MULTI_Q_MSG"
        elif pane_is_fork "$pane"; then
            command printf '%s\t%s\n' "$sess" "escalation — awaiting decision (carries options)"
        elif pane_is_api_error "$pane"; then
            # BEFORE pane_is_turn_end: a died-on-API-error pane also paints the bare
            # turn-end footer, so the more-specific death read must win (#446).
            command printf '%s\t%s: %s (check pane)\n' \
                "$sess" "$DIED_MSG_PREFIX" "$(pane_api_error_class "$pane")"
        elif pane_is_turn_end "$pane"; then
            command printf '%s\t%s\n' "$sess" "$TURN_END_MSG"
        fi
    done
}

# Two-consecutive-poll confirmation for the turn-end/idle-at-prompt signal (#447).
# The raw panes_snapshot() emits $TURN_END_MSG the instant a golem's footer looks
# idle. A golem momentarily BETWEEN turns — one response finished, the next
# instruction/tool-result not yet rendered — can paint exactly that footer for a
# single --stream-panes tick, which would push a false "idle at prompt". The issue
# asks for the signal to be "confirmed across two consecutive polls to avoid firing
# on a normal turn boundary", so this filter suppresses a turn-end line on the
# FIRST poll it appears and passes it only once the SAME golem is still turn-ended
# on the NEXT poll. Every other line (plan/permission/fork gate) passes through
# untouched — those are modal overlays that do not flicker between turns.
#
# State is the space-delimited set PENDING_TURN_END (golems seen idle last poll but
# not yet confirmed), threaded like emit_transitions' LAST_EMIT: a bash-3.2-clean
# module global (no `declare -A`). A golem that clears (drops out of the snapshot,
# or its line changes to a real gate) is dropped from the pending set, so a later
# re-idle re-confirms from scratch.
#
# CRITICAL: like emit_transitions, this MUST run in the caller's shell (not a
# `$(...)` subshell) or its PENDING_TURN_END mutation is discarded and the debounce
# never confirms. So it does NOT print — it takes the snapshot as $1 and writes the
# filtered snapshot to the global CONFIRMED_SNAPSHOT, mutating PENDING_TURN_END in
# place. The caller reads CONFIRMED_SNAPSHOT and hands it to emit_transitions.
PENDING_TURN_END=" "
CONFIRMED_SNAPSHOT=""
confirm_turn_end() {
    local snapshot="$1"
    local nextpending=" " out="" golem msg
    while IFS=$'\t' read -r golem msg; do
        [ -z "$golem" ] && continue
        if [ "$msg" = "$TURN_END_MSG" ]; then
            if _set_has "$PENDING_TURN_END" "$golem"; then
                # Confirmed: idle on two consecutive polls — pass it through and KEEP
                # pending so it is not re-suppressed while the stall persists (dedup
                # of the standing line is emit_transitions' job downstream).
                out="${out}${golem}"$'\t'"${msg}"$'\n'
                _set_has "$nextpending" "$golem" || nextpending="${nextpending}${golem} "
            else
                # First idle poll for this golem: hold it back, mark pending.
                nextpending="${nextpending}${golem} "
            fi
        else
            # A non-turn-end line (real gate) passes straight through.
            out="${out}${golem}"$'\t'"${msg}"$'\n'
        fi
    done <<<"$snapshot"
    PENDING_TURN_END="$nextpending"
    CONFIRMED_SNAPSHOT="$out"
}

# Classify a captured pane for the liveness sweep (issue #229). Unlike the
# gate matchers above (which detect a modal permission/plan OVERLAY), this reads
# the ordinary session surface to tell "actually working" from "idle/errored at
# the prompt" — the distinction the mtime heartbeat cannot make.
#   "working" — the `esc to interrupt` run-spinner hint is in the footer; the
#               reliable positive "a command is executing right now" marker.
#   "died"    — the #446 API-error death signature (`API Error` + a 4xx/5xx code)
#               in the scrollback with no run-spinner: the `claude` process died
#               on a transient (429/5xx) or terminal (auth/quota) API error and is
#               parked at its prompt looking exactly like a finished turn. Checked
#               before the plain idle arms so it is not downgraded to `idle`.
#   "idle"    — an error/idle signature: the exact #229 `Unknown command`
#               failure, or the bare `auto mode on` footer (the `⏵⏵ auto mode on`
#               chrome) with no spinner above it (orchestrate golems always run
#               auto mode, so that footer with no spinner means the session is
#               parked at its prompt).
#   ""        — indeterminate (e.g. a transient mid-render capture); the caller
#               falls back to the mtime heartbeat.
# Matching is ANCHORED to the FOOTER region — only the last $pane_footer_lines
# lines of the capture, where the spinner/input-box/footer chrome renders — NOT
# the whole scrollback. Anchoring is what makes the classifier robust against a
# golem whose scrolled conversation/code happens to contain a trigger phrase:
# this very script's comments carry `esc to interrupt`, `Unknown command`, and
# `auto mode on`, and a golem reading them would otherwise self-trip the match
# (fail-loud a false idle, or fail-open a false working that suppresses #229
# detection). See issue #246. The `auto mode on` idle footer additionally
# requires its `⏵⏵` box-drawing glyph, so a bare-words mention that lands in the
# window still stays indeterminate. The spinner is checked FIRST so it wins even
# when the `auto mode on` footer is also painted (a working golem still shows the
# footer). Prints the class.
pane_liveness_class() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"esc to interrupt"*)
            command echo "working"
            return 0
            ;;
    esac
    # #446 death read BEFORE the plain idle arms: a died-on-API-error pane also
    # paints the bare `auto mode on` footer, so without this it would classify as a
    # plain `idle` and mask the death. pane_is_api_error carries its own
    # spinner-in-footer guard (redundant with the `working` return above, kept for
    # standalone correctness).
    if pane_is_api_error "$1"; then
        command echo "died"
        return 0
    fi
    case "$footer" in
        *"Unknown command"*)
            command echo "idle"
            return 0
            ;;
    esac
    # #517: a golem parked on its OWN background monitors / a running dynamic
    # workflow / the review harness paints the bare `⏵⏵ auto mode on` footer with no
    # spinner — identical to a real idle — but is alive with a queued next action.
    # Return "" (indeterminate) so the caller falls through to the mtime heartbeat,
    # which reports it advancing, instead of a false `idle`. Checked before the
    # auto-mode-on arm; the same guard the push channel (pane_is_turn_end) uses, so
    # both idle reads stay consistent. (The `Unknown command` #229 error arm above
    # is a genuine idle-at-error, NOT an own-work park, so it is not guarded.)
    if pane_pending_own_work "$1"; then
        command echo ""
        return 0
    fi
    case "$footer" in
        *"⏵⏵"*"auto mode on"*)
            command echo "idle"
            return 0
            ;;
    esac
    command echo ""
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
    m="$("$STAT" -c %Y "$path" 2>/dev/null || "$STAT" -f %m "$path" 2>/dev/null || true)"
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
        done < <(tmux ls 2>/dev/null | "$GREP" -oE '^golem-[0-9]+' || true)
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

    local now act age pane pclass tclass
    now="$("$DATE" +%s)"
    # Stable numeric order so successive snapshots line up for the operator.
    for n in $(command echo "$golems" | "$TR" ' ' '\n' | "$SORT" -n); do
        [ -z "$n" ] && continue
        if _set_has "$gated" "$n"; then
            command printf '%s\t%s\n' "golem-$n" "gated — awaiting decision (not a stall)"
            continue
        fi
        # Prefer a live pane read over the mtime heartbeat: it can tell "actually
        # working" (run-spinner) from "idle/errored at the prompt" (#229), which
        # the mtime proxy cannot. Best-effort — a headless/container golem with
        # no host-visible tmux session yields no class and falls through to the
        # transcript tier below.
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "golem-$n" 2>/dev/null; then
            pane="$(tmux capture-pane -p -t "golem-$n" 2>/dev/null || true)"
            if [ -n "$pane" ]; then
                pclass="$(pane_liveness_class "$pane")"
                case "$pclass" in
                    working)
                        command printf '%s\t%s\n' "golem-$n" "alive, working (esc-to-interrupt active)"
                        continue
                        ;;
                    died)
                        command printf '%s\t%s: %s (check pane)\n' \
                            "golem-$n" "$DIED_MSG_PREFIX" "$(pane_api_error_class "$pane")"
                        continue
                        ;;
                    idle)
                        command printf '%s\t%s\n' "golem-$n" "⚠ idle at prompt — process up, not advancing (check pane)"
                        continue
                        ;;
                esac
            fi
        fi
        # Transcript tier (#248): the pane read did not classify this golem — it
        # has no host-visible tmux session (headless / CI / container-visible-only)
        # or the pane was indeterminate. Read the same working/idle/errored signal
        # from the golem's on-disk Claude Code transcript, which needs no TTY, so a
        # headless golem that errored on line 1 and went idle (#229) is caught here
        # instead of falling through to the mtime heartbeat that cannot see it.
        # Best-effort like the pane read: any non-zero exit (no host transcript —
        # e.g. a Mode-3 container golem — / no jq / indeterminate) falls through to
        # the mtime heartbeat below. golem-transcript-liveness.sh resolves the same
        # <projects>/<slug>/ transcript golem-token-scrape.sh does.
        if [ -x "$SCRIPT_DIR/golem-transcript-liveness.sh" ]; then
            tclass="$("$SCRIPT_DIR/golem-transcript-liveness.sh" \
                "$root/$GOLEM_WORKTREE_DIR/issue-$n" 2>/dev/null || true)"
            case "$tclass" in
                working)
                    command printf '%s\t%s\n' "golem-$n" "alive, working (transcript: turn in flight)"
                    continue
                    ;;
                idle)
                    command printf '%s\t%s\n' "golem-$n" "⚠ idle at prompt — process up, not advancing (transcript: turn ended)"
                    continue
                    ;;
                errored)
                    command printf '%s\t%s\n' "golem-$n" "⚠ idle at prompt — errored and idle (transcript: command error, check pane)"
                    continue
                    ;;
            esac
        fi
        act="$(_golem_last_activity "$n" "$root" "$status_dir")"
        [ -z "$act" ] && continue
        age=$((now - act))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$stall_threshold" ]; then
            command printf '%s\t%s\n' "golem-$n" "possible stall — no progress for $(_fmt_age "$age")"
        else
            command printf '%s\t%s\n' "golem-$n" "alive (process up, last activity $(_fmt_age "$age") ago)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Liveness stream dedup (issue #489)
# ---------------------------------------------------------------------------
# The liveness stream used to re-emit every golem's line every
# GOLEM_HEARTBEAT_INTERVAL unconditionally — ~one line per golem per minute even
# when nothing changed, drowning the actionable transitions (working→idle,
# alive→stall, →gated). The gate channels (--stream/--stream-panes) never had this
# problem: they route through emit_transitions, which suppresses a standing line
# and emits only on a real per-golem change. #489 gives liveness the same dedup.
#
# emit_transitions keys on the EXACT per-golem message, so a message carrying a
# per-tick-volatile substring would defeat it — every tick would read as a new
# transition. Only two liveness lines are volatile: the mtime-heartbeat strings
# carry a `_fmt_age` value (`Nm`/`Ns`) that ticks every poll. liveness_stabilize
# canonicalizes those two to a stable CLASS (dropping the age) so a steady-state
# golem produces a byte-identical message tick-to-tick and emit_transitions
# suppresses it; a genuine class change (alive↔stall, →working, →idle, →gated)
# still changes the message and emits. Every other liveness line (working / idle /
# died / gated) is already age-free and passes through verbatim.
#
# The FULL-detail age is preserved on the PULL surface: --once-liveness and
# golem-status.sh's snapshot call liveness_snapshot directly, not this. Only the
# --stream-liveness push arm stabilizes, and only to gate the dedup.
liveness_stabilize() {
    local snapshot="$1" golem msg
    while IFS=$'\t' read -r golem msg; do
        [ -z "$golem" ] && continue
        case "$msg" in
            "alive (process up, last activity "*)
                msg="alive (process up)"
                ;;
            "possible stall — no progress for "*)
                msg="possible stall"
                ;;
        esac
        command printf '%s\t%s\n' "$golem" "$msg"
    done <<<"$snapshot"
}

# summary_due <elapsed_seconds> <interval_seconds> — cadence gate for the slow
# aggregate liveness summary. Returns 0 (due) when elapsed >= interval; 1 (not
# due) when below, OR when interval is 0 (summary disabled) or non-numeric (a
# garbage GOLEM_LIVENESS_SUMMARY_INTERVAL must never crash the watch). Isolated
# as a pure function so the numeric guard is unit-testable without the infinite
# --stream-liveness loop. bash-3.2 clean (no arithmetic on unvalidated input).
summary_due() {
    local elapsed="$1" interval="$2"
    case "$elapsed" in '' | *[!0-9]*) return 1 ;; esac
    case "$interval" in '' | *[!0-9]* | 0) return 1 ;; esac
    [ "$elapsed" -ge "$interval" ] && return 0
    return 1
}

# summary_enabled <interval_seconds> — true when the aggregate summary is enabled
# at all (a positive numeric interval). A 0 or non-numeric interval disables the
# summary ENTIRELY, so the drive arm gates even the ONE-TIME startup summary on
# this (not just the periodic re-emission on summary_due) — otherwise interval=0
# would still print one startup line, contradicting the documented "0 disables it"
# (#489 review). Shares summary_due's numeric-guard shape; bash-3.2 clean.
summary_enabled() {
    case "$1" in '' | *[!0-9]* | 0) return 1 ;; esac
    return 0
}

# liveness_summary <snapshot> — collapse a liveness snapshot to ONE aggregate
# fleet line so the transition-deduped stream still carries a periodic positive
# "the watch is alive" heartbeat without the per-golem flood (issue #489). Counts
# each golem's class from its message; `alive, working` (pane/transcript spinner)
# and the mtime `process up` heartbeat both count as "alive". Emits nothing on an
# empty snapshot (no golems ⇒ nothing to summarize). One line per fleet, so at the
# default 15-min cadence this is ~60× less volume than the old per-golem minute
# heartbeat. Output: "liveness-summary\tA alive, I idle, S stalled, G gated, D died (N golems)".
liveness_summary() {
    local snapshot="$1" golem msg
    local alive=0 idle=0 stalled=0 gated=0 died=0 total=0
    while IFS=$'\t' read -r golem msg; do
        [ -z "$golem" ] && continue
        total=$((total + 1))
        case "$msg" in
            *"died — API error"*) died=$((died + 1)) ;;
            *"idle at prompt"*) idle=$((idle + 1)) ;;
            *"possible stall"*) stalled=$((stalled + 1)) ;;
            *"gated"*) gated=$((gated + 1)) ;;
            *"alive"*) alive=$((alive + 1)) ;;
        esac
    done <<<"$snapshot"
    [ "$total" -eq 0 ] && return 0
    command printf '%s\t%d alive, %d idle, %d stalled, %d gated, %d died (%d golems)\n' \
        "liveness-summary" "$alive" "$idle" "$stalled" "$gated" "$died" "$total"
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
            [ -n "$feed" ] && feed_snapshot_live "$feed"
            exit 0
            ;;
        --once-panes)
            panes_snapshot
            exit 0
            ;;
        --stream)
            # Prime from the current state so pre-existing gates are not replayed as
            # new, then emit only genuine transitions thereafter. feed_snapshot_live
            # applies the #446 ghost filter so a torn-down golem never streams as a
            # fresh transition.
            [ -n "$feed" ] && emit_transitions "$(feed_snapshot_live "$feed")" 1
            while :; do
                "$SLEEP" "$interval"
                [ -n "$feed" ] && emit_transitions "$(feed_snapshot_live "$feed")" 0
            done
            ;;
        --stream-panes)
            # panes_snapshot -> confirm_turn_end -> emit_transitions. confirm_turn_end
            # applies the two-consecutive-poll debounce to the turn-end/idle line only
            # (#447): a golem must look idle on two successive polls before its line is
            # passed on, so a momentary between-turns render never pushes a false idle;
            # real gates (plan/permission/fork) pass straight through. emit_transitions
            # then dedups the confirmed standing line to a single push. Note this means
            # a genuine idle takes prime + 1 poll (two observations) to surface — the
            # confirmation the issue asks for.
            # confirm_turn_end and emit_transitions BOTH mutate module state, so
            # each must run in THIS shell — only the inner panes_snapshot capture is
            # a subshell. confirm_turn_end writes CONFIRMED_SNAPSHOT; emit_transitions
            # reads it.
            confirm_turn_end "$(panes_snapshot)"
            emit_transitions "$CONFIRMED_SNAPSHOT" 1
            while :; do
                "$SLEEP" "$interval"
                confirm_turn_end "$(panes_snapshot)"
                emit_transitions "$CONFIRMED_SNAPSHOT" 0
            done
            ;;
        --once-liveness)
            liveness_snapshot "$status_dir" "$feed"
            exit 0
            ;;
        --stream-liveness)
            # Transition-deduped (issue #489). The heartbeat used to re-emit every
            # golem's line every GOLEM_HEARTBEAT_INTERVAL unconditionally, flooding
            # live context with "still alive" lines that said nothing changed. Now it
            # routes each snapshot through liveness_stabilize (drops the volatile
            # mtime age so a steady class is byte-identical tick-to-tick) then
            # emit_transitions — the SAME per-golem dedup the gate channels use — so
            # only a real class change (working→idle, alive→stall, →gated, →died)
            # emits a line. A slow aggregate liveness_summary line still confirms the
            # watch is alive without the per-golem flood: emitted once at startup and
            # then every GOLEM_LIVENESS_SUMMARY_INTERVAL. A 0 (or non-numeric)
            # interval disables the summary ENTIRELY — including the startup line —
            # via summary_enabled(), so "0 disables it" holds literally (#489 review).
            # emit_transitions mutates the module-global LAST_EMIT, so — like the
            # --stream / --stream-panes arms — it MUST run in THIS shell, not a
            # subshell; only the inner liveness_snapshot capture is a subshell.
            snap="$(liveness_snapshot "$status_dir" "$feed")"
            emit_transitions "$(liveness_stabilize "$snap")" 1
            summary_enabled "$summary_interval" && liveness_summary "$snap"
            since_summary=0
            while :; do
                "$SLEEP" "$heartbeat_interval"
                snap="$(liveness_snapshot "$status_dir" "$feed")"
                emit_transitions "$(liveness_stabilize "$snap")" 0
                since_summary=$((since_summary + heartbeat_interval))
                if summary_due "$since_summary" "$summary_interval"; then
                    liveness_summary "$snap"
                    since_summary=0
                fi
            done
            ;;
    esac

fi
