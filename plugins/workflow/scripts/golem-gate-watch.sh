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
#           "escalation — …" line so the operator knows it carries options. Live
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
# session errored on line 1 and went idle at its prompt (issue #229). So when a
# live golem-* tmux pane is scrapeable, `pane_liveness_class` overrides the mtime
# proxy with a stronger read: "alive, working" when the `esc to interrupt` run-
# spinner is in the footer, or "⚠ idle at prompt" on an error/idle signature. The
# match is anchored to the pane's FOOTER region (the last GOLEM_PANE_FOOTER_LINES
# lines, where the spinner/input-box/footer chrome renders) rather than the whole
# scrollback, so a golem cat-ing/grepping a file whose text happens to contain
# those trigger phrases — this very script does — does not self-trip the
# classifier (issue #246). The pane check is best-effort — headless/container
# golems the host tmux can't see fall back to the reworded mtime heartbeat.
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
#                            gate OR turn-ended/idle at their prompt (#447)
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
#   GOLEM_PANE_FOOTER_LINES  pane footer window for pane_liveness_class +
#                            pane_is_fork, lines (default 8)
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
pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"

# The turn-end/idle-at-prompt push message (#447). Defined once here because two
# functions couple on it: panes_snapshot() emits it, and confirm_turn_end()
# recognizes it to apply the two-consecutive-poll debounce (below). A top-level
# assignment so a SOURCED unit test sees it before calling either function.
TURN_END_MSG="⚠ idle at prompt — turn ended, awaiting input (check pane)"

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
# from a session with no GOLEM_ID that is not in a worktree root (the
# orchestrator's own session, a plain `claude` in the main checkout). No real
# golem ever carries that id, so no future `idle` supersedes it, and a no-`ts`
# line bypasses the TTL by design (#24) — so an orphan `golem-?` gate would stay
# BLOCKED forever. It is never actionable anyway (`golem-?` has no golem-attach
# target), so it is never surfaced as a block.
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
            | map(select(.golem != "golem-?"))
            | map(select((.event == "gate" or .event == "blocked" or .event == "escalation" or .event == "dead-end")
                         and (if (.ts | type) == "string" and .ts != ""
                              then (($now - (.ts | fromdateiso8601)) < $ttl)
                              else true end)))
            | .[]
            | (.message // "awaiting decision") as $m
            | if .event == "dead-end" then "\(.golem)\tdead-end — \($m)"
              elif .event == "escalation" then "\(.golem)\tescalation — \($m)"
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
    footer="$(/usr/bin/tail -n "$pane_footer_lines" <<<"$1")"
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
    footer="$(/usr/bin/tail -n "$pane_footer_lines" <<<"$1")"
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
    footer="$(/usr/bin/tail -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Enter to select"*) return 0 ;;
    esac
    return 1
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
# state, re-fired only after it clears) rather than the un-deduped
# --stream-liveness heartbeat that a Monitor push arm would drown in.
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
pane_is_turn_end() {
    local footer
    footer="$(/usr/bin/tail -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    case "$footer" in
        *"⏵⏵"*"auto mode on"*) return 0 ;;
    esac
    return 1
}

# Print the current set of live golem-* sessions sitting at a prompt overlay,
# one "<golem>\t<message>" line each. No-op (success) when tmux is absent.
#
# Dispatch order is load-bearing: plan-gate → permission-gate → escalation fork →
# turn-end. Each modal matcher is checked before pane_is_turn_end so a real
# overlay is classified as itself, never downgraded to the last-resort idle read
# (a modal prompt still renders the `auto mode on` footer underneath it). This is
# the same precedence discipline the fork branch already relies on.
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
        elif pane_is_fork "$pane"; then
            /usr/bin/printf '%s\t%s\n' "$sess" "escalation — awaiting decision (carries options)"
        elif pane_is_turn_end "$pane"; then
            /usr/bin/printf '%s\t%s\n' "$sess" "$TURN_END_MSG"
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
    footer="$(/usr/bin/tail -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"esc to interrupt"*)
            command echo "working"
            return 0
            ;;
    esac
    case "$footer" in
        *"Unknown command"*)
            command echo "idle"
            return 0
            ;;
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

    local now act age pane pclass
    now="$(/usr/bin/date +%s)"
    # Stable numeric order so successive snapshots line up for the operator.
    for n in $(command echo "$golems" | /usr/bin/tr ' ' '\n' | /usr/bin/sort -n); do
        [ -z "$n" ] && continue
        if _set_has "$gated" "$n"; then
            /usr/bin/printf '%s\t%s\n' "golem-$n" "gated — awaiting decision (not a stall)"
            continue
        fi
        # Prefer a live pane read over the mtime heartbeat: it can tell "actually
        # working" (run-spinner) from "idle/errored at the prompt" (#229), which
        # the mtime proxy cannot. Best-effort — a headless/container golem with
        # no host-visible tmux session yields no class and falls through to the
        # mtime heartbeat below.
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "golem-$n" 2>/dev/null; then
            pane="$(tmux capture-pane -p -t "golem-$n" 2>/dev/null || true)"
            if [ -n "$pane" ]; then
                pclass="$(pane_liveness_class "$pane")"
                case "$pclass" in
                    working)
                        /usr/bin/printf '%s\t%s\n' "golem-$n" "alive, working (esc-to-interrupt active)"
                        continue
                        ;;
                    idle)
                        /usr/bin/printf '%s\t%s\n' "golem-$n" "⚠ idle at prompt — process up, not advancing (check pane)"
                        continue
                        ;;
                esac
            fi
        fi
        act="$(_golem_last_activity "$n" "$root" "$status_dir")"
        [ -z "$act" ] && continue
        age=$((now - act))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$stall_threshold" ]; then
            /usr/bin/printf '%s\t%s\n' "golem-$n" "possible stall — no progress for $(_fmt_age "$age")"
        else
            /usr/bin/printf '%s\t%s\n' "golem-$n" "alive (process up, last activity $(_fmt_age "$age") ago)"
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
                /usr/bin/sleep "$interval"
                confirm_turn_end "$(panes_snapshot)"
                emit_transitions "$CONFIRMED_SNAPSHOT" 0
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
