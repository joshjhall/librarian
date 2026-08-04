#!/usr/bin/env bash
# golem-mode-check.sh — detect (and optionally auto-correct) PERMISSION-MODE
# DRIFT in live golems: a golem still sitting in plan mode long after its plan
# was approved (issue #659).
#
# The failure it closes: two golems dispatched at L3 stayed in plan mode for
# their whole implementation phase. Every Edit/Write raised a permission prompt
# — ~40 hand-approvals across two golems — so L3 ("plan-gated, then autonomous
# to a green PR") silently degraded to L1. Nothing errored. The only tell was
# the pane footer, which reads as cosmetic while the golem narrates file writes,
# so ~90 minutes went into trust state, settings.local.json and classifier
# behavior before the operator spotted it.
#
# MODE WITHOUT PHASE IS NOT A VIOLATION — the load-bearing rule
# ------------------------------------------------------------
# Plan mode is perfectly LEGAL before ExitPlanMode: that is the entire point of
# a plan-gated level. A naive footer grep fires on every golem that is
# correctly mid-research, and the first hand-rolled version of this check did
# exactly that. So a golem is flagged only when its mode is plan AND its phase
# is definitively PAST planning.
#
# This gate is load-bearing for the AUTO-CORRECT, not just the alert. A
# correction sent to a golem that is legitimately planning would kick it out of
# plan mode mid-design and skip the very gate its level exists to enforce —
# silently turning an L3 run into an L4 one. That is a WORSE failure than the
# bug being fixed, so the phase gate guards both paths.
#
# Phase is inferred from TWO sources, deliberately:
#   1. PRIMARY — the golem's next-issue-{N}.json `phase` field. Direct, but can
#      be stale or absent (a worktree dispatch may never write one).
#   2. CORROBORATING — `git rev-list --count <base>..HEAD` in the worktree. A
#      golem with commits beyond base is past planning BY DEFINITION, and this
#      is never wrong in the false-positive direction. It stands alone when the
#      state file is missing or stale.
# Either source claiming "past planning" is enough; neither claiming it means
# the golem is treated as still planning (fail SAFE — toward not correcting).
#
# FAIL LOUD, never a silent clean report
# --------------------------------------
# Missing tmux (or jq, when a state file must be read) exits NON-ZERO with an
# actionable message. A check that reports "no drift" because it could not look
# is indistinguishable from a working check — that is how a gate sits inert
# unnoticed (the #538/#571 skip-sentinel lesson).
#
# NEVER FIRE-AND-FORGET A KEYSTROKE
# ---------------------------------
# This entire bug class is "the keystroke did not do what was assumed". So the
# auto-correct sends, then RE-SCRAPES to confirm the transition landed, retrying
# up to GOLEM_MODE_FIX_ATTEMPTS times before escalating to the operator. The
# same send-then-verify primitive (verify_send) also closes the issue's rider: a
# `tmux send-keys` to a golem with a permission modal open is silently swallowed
# — the text goes nowhere and never reaches the transcript. Two such sends were
# lost during the reported session and were only caught by grepping the golem's
# transcript afterward.
#
# Every correction is reported LOUDLY. A golem silently put back into a working
# mode still gets a line and a feed entry, because a RECURRING correction means
# the root cause is still live — which silence would hide.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR        (.worktrees)
#   GOLEM_STATUS_DIR          (.worktrees/.status)
#   GOLEM_BASE_REF            (origin/main) — the rev-list base
#   GOLEM_MODE_FIX_ATTEMPTS   (3)  per-golem auto-correct bound
#   GOLEM_MODE_CHECK_INTERVAL (60) --watch cadence, seconds
#   GOLEM_PANE_FOOTER_LINES   (8)  footer window, shared with golem-gate-watch.sh
#
# Usage:
#   golem-mode-check.sh                    one-shot report (default; --once)
#   golem-mode-check.sh --fix              report + bounded auto-correct
#   golem-mode-check.sh --watch [--fix]    poll until killed
#   golem-mode-check.sh --interval S       override the --watch cadence
#   golem-mode-check.sh verify-send <N> <keys...>
#                                          send keys to golem-N and CONFIRM the
#                                          pane changed (the swallowed-send guard)
#
# Exit status (one-shot): 0 no drift · 1 drift found (report mode) or a golem
# could not be corrected (--fix) · 2 usage/environment error (fail-loud).
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# Mirrors golem-status.sh / golem-gate-watch.sh: honor PATH first (the
# `command -v` builtin needs no external binary), then scan the standard bin
# dirs so this still resolves under a stripped PATH, then yield the bare name.
# Candidates are bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443
# lint does not flag them.
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
DIRNAME="$(_bin dirname)"
GREP="$(_bin grep)"
SED="$(_bin sed)"
SLEEP="$(_bin sleep)"
TAIL="$(_bin tail)"

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

root="$(repo_root)"
resolver="$SCRIPT_DIR/autonomy-resolve.sh"

# Footer window shared with golem-gate-watch.sh, same env knob so the two agree.
pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"

# ---------------------------------------------------------------------------
# Mode classification
# ---------------------------------------------------------------------------
# Claude Code paints the current permission mode in the pane FOOTER. The three
# shapes we care about are the plan-mode indicator, the auto-mode indicator, and
# the accept-edits indicator, each led by a distinctive box-drawing glyph.
#
# Two guards, both borrowed from golem-gate-watch.sh's matcher discipline
# (#246/#452), and BOTH load-bearing here:
#
#   1. FOOTER-ANCHORED. Match only the last $pane_footer_lines lines, never the
#      whole scrollback. This script and its tests necessarily discuss these
#      very phrases, so a golem reading/grepping either file would self-trip a
#      whole-scrollback matcher into a false drift report — and under --fix, a
#      false CORRECTION.
#   2. GLYPH-REQUIRED. Each arm requires its box-drawing glyph, so a bare-words
#      mention in prose or work output stays unmatched. The glyphs are built
#      from \u escapes via printf rather than written literally, so this file
#      does not contain a matchable footer even inside the footer window of a
#      pane that happens to be displaying it.
MODE_GLYPH_PLAN="$(command printf '\342\217\270')"             # pause bar — plan mode
MODE_GLYPH_AUTO="$(command printf '\342\217\265\342\217\265')" # double chevron — auto mode

# pane_mode_class <pane-text> — echo the golem's current mode:
#   plan | auto | accept-edits | unknown
# `unknown` is the honest answer for a pane with no readable mode footer (a
# fresh session, a full-screen modal, a cleared pane); callers must treat it as
# "cannot tell", never as a violation and never as a licence to correct.
pane_mode_class() {
    _pmc_footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$_pmc_footer" in
        *"$MODE_GLYPH_PLAN"*"plan mode on"*)
            command echo "plan"
            return 0
            ;;
        *"$MODE_GLYPH_AUTO"*"auto mode on"*)
            command echo "auto"
            return 0
            ;;
        *"$MODE_GLYPH_AUTO"*"accept edits on"*)
            command echo "accept-edits"
            return 0
            ;;
    esac
    command echo "unknown"
}

# ---------------------------------------------------------------------------
# Phase inference
# ---------------------------------------------------------------------------

# golem_state_phase <issue-n> — the `phase` field from the golem's per-issue
# next-issue state file inside its worktree, or empty when unreadable/absent.
# PRIMARY signal, but advisory: a Mode-2 worktree dispatch may never write one,
# and a live golem can lag it. Never fails the caller — an unreadable state file
# simply yields no opinion and lets the commit-count arm decide.
golem_state_phase() {
    _gsp_n="$1"
    _gsp_f="$root/$GOLEM_WORKTREE_DIR/issue-$_gsp_n/.claude/memory/tmp/next-issue-$_gsp_n.json"
    [ -f "$_gsp_f" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.phase // empty' "$_gsp_f" 2>/dev/null || true
}

# golem_commit_count <issue-n> — commits on the golem's branch beyond the base
# ref, or empty when it cannot be determined (no worktree, no git, unborn base).
# CORROBORATING signal: a golem with commits is past planning BY DEFINITION, so
# this is never wrong in the false-positive direction — which is exactly why it
# is trusted even when the state file disagrees or is missing.
golem_commit_count() {
    _gcc_n="$1"
    _gcc_wt="$root/$GOLEM_WORKTREE_DIR/issue-$_gcc_n"
    [ -d "$_gcc_wt" ] || return 0
    _gcc_c="$(git -C "$_gcc_wt" rev-list --count "$GOLEM_BASE_REF"..HEAD 2>/dev/null || true)"
    case "$_gcc_c" in
        '' | *[!0-9]*) return 0 ;;
        *) command echo "$_gcc_c" ;;
    esac
}

# golem_past_planning <issue-n> — 0 when the golem is DEFINITIVELY past its
# planning phase, 1 otherwise (including "cannot tell").
#
# Fails SAFE toward "still planning": when neither source has an opinion we do
# NOT flag, because a false positive here means yanking a designing golem out of
# plan mode and skipping its gate. Under-reporting costs a missed correction the
# next poll catches; over-reporting silently converts L3 into L4.
golem_past_planning() {
    _gpp_n="$1"
    # Corroborating arm first — it is the one that is never wrong in the
    # false-positive direction, and it holds when the state file is stale/absent.
    _gpp_commits="$(golem_commit_count "$_gpp_n")"
    if [ -n "$_gpp_commits" ] && [ "$_gpp_commits" -gt 0 ]; then
        return 0
    fi
    # Primary arm: an explicit post-planning phase in the state file. `select`
    # and `plan` are planning-or-earlier; anything past them counts.
    case "$(golem_state_phase "$_gpp_n")" in
        implement | ship) return 0 ;;
    esac
    return 1
}

# expected_mode <level> — the mode a golem at <level> SHOULD be in once past
# planning, delegated to autonomy-resolve.sh rather than hardcoded here.
#
# This matters: issue #659's invariant table proposed `acceptEdits` for L1-L3,
# but the resolver is `acceptEdits` only at L1 and `auto` for L2-L4, and
# golem-launch.sh launches every golem with `--permission-mode auto`. Hardcoding
# the issue's table would flag every HEALTHY L3 golem as a violation. The
# resolver is the single source of truth for per-level dispositions (#190), so
# we ask it. Empty on failure — the caller then reports drift without naming an
# expected mode rather than inventing one.
expected_mode() {
    _em_level="$1"
    [ -x "$resolver" ] || return 0
    _em_out="$("$resolver" level --chosen-level "$_em_level" 2>/dev/null || true)"
    command printf '%s\n' "$_em_out" |
        "$GREP" -E '^perm_mode=' 2>/dev/null | "$SED" -e 's/^perm_mode=//' || true
}

# ---------------------------------------------------------------------------
# Send verification (the #659 rider)
# ---------------------------------------------------------------------------

# verify_send <session> <expect-fn> <keys...> — send keystrokes to a golem pane
# and CONFIRM they took effect, rather than assuming delivery.
#
# A `tmux send-keys` to a golem with a permission modal open is silently
# swallowed: the keys go nowhere and never reach the transcript. That bit the
# reported session twice (an orchestrator correction and a pointer to a failing
# test both vanished, caught only by grepping the transcript afterward). tmux
# itself reports success — it delivered to the pane; the application discarded
# it — so the exit status of send-keys proves nothing.
#
# <expect-fn> is a predicate taking the freshly-scraped pane text and returning 0
# once the send has demonstrably landed. Returns 0 when confirmed, 1 when the
# pane never reached the expected state (swallowed, or the mode would not stick).
verify_send() {
    _vs_sess="$1"
    _vs_expect="$2"
    shift 2
    tmux send-keys -t "$_vs_sess" "$@" 2>/dev/null || return 1
    # Give the pane a moment to repaint before re-scraping; a same-instant
    # capture races the redraw and would read the PRE-send footer, reporting a
    # false "did not land" for a send that actually worked.
    "$SLEEP" 1
    _vs_pane="$(tmux capture-pane -p -t "$_vs_sess" 2>/dev/null || true)"
    [ -n "$_vs_pane" ] || return 1
    "$_vs_expect" "$_vs_pane"
}

# _expect_not_plan <pane-text> — the verify_send predicate for a mode
# correction: the golem has left plan mode. Deliberately "not plan" rather than
# "== auto": a correction that lands in accept-edits still cleared the #659
# condition (edits stop being plan-blocked), and treating that as failure would
# burn the retry budget on an already-fixed golem.
_expect_not_plan() {
    [ "$(pane_mode_class "$1")" != "plan" ]
}

# ---------------------------------------------------------------------------
# Check + correct
# ---------------------------------------------------------------------------

# report_correction <golem> <message> — emit the loud line AND a feed entry.
# The feed entry is what makes a RECURRING correction visible across sweeps: a
# golem that has to be corrected repeatedly means the root cause is still live,
# and the issue is explicit that a silent auto-fix would hide exactly that.
# Best-effort — a missing notify hook never fails the check.
report_correction() {
    _rc_golem="$1"
    _rc_msg="$2"
    command echo "$_rc_golem — $_rc_msg"
    if [ -x "$SCRIPT_DIR/golem-resolve.sh" ]; then
        "$SCRIPT_DIR/golem-resolve.sh" "$_rc_golem" "mode-check: $_rc_msg" >/dev/null 2>&1 || true
    fi
}

# check_once <fix?> — scan every live golem-* session once. Echoes one line per
# finding; returns 0 when every golem is healthy, 1 when drift was found and (in
# fix mode) could not be corrected.
check_once() {
    _co_fix="$1"
    _co_rc=0
    _co_sessions="$(tmux ls 2>/dev/null | "$GREP" -oE '^golem-[0-9]+' || true)"
    if [ -z "$_co_sessions" ]; then
        command echo "No live golem-* tmux sessions."
        return 0
    fi

    for _co_sess in $_co_sessions; do
        _co_n="${_co_sess#golem-}"
        _co_pane="$(tmux capture-pane -p -t "$_co_sess" 2>/dev/null || true)"
        if [ -z "$_co_pane" ]; then
            command echo "$_co_sess — pane unreadable (cannot classify mode)"
            continue
        fi

        _co_mode="$(pane_mode_class "$_co_pane")"
        [ "$_co_mode" = "plan" ] || continue

        # In plan mode. LEGAL while planning — the phase gate decides.
        if ! golem_past_planning "$_co_n"; then
            continue
        fi

        _co_rc=1
        _co_exp="$(expected_mode "${GOLEM_LEVEL:-4}")"
        _co_detail="in plan mode past the planning phase"
        [ -n "$_co_exp" ] && _co_detail="$_co_detail (expected $_co_exp)"

        if [ "$_co_fix" -eq 0 ]; then
            command echo "$_co_sess — DRIFT: $_co_detail — rerun with --fix to correct"
            continue
        fi

        # Bounded auto-correct. Each attempt SENDS then RE-SCRAPES; we never
        # assume the keystroke did what we asked.
        _co_attempt=1
        _co_fixed=0
        while [ "$_co_attempt" -le "$GOLEM_MODE_FIX_ATTEMPTS" ]; do
            if verify_send "$_co_sess" _expect_not_plan S-Tab; then
                report_correction "$_co_sess" \
                    "auto-corrected out of plan mode on attempt $_co_attempt ($_co_detail)"
                _co_fixed=1
                _co_rc=0
                break
            fi
            _co_attempt=$((_co_attempt + 1))
        done

        if [ "$_co_fixed" -eq 0 ]; then
            # ESCALATE rather than loop. A mode that will not stick is a genuine
            # lock, and spinning keystrokes at it forever is the failure mode the
            # issue explicitly asks us to bound.
            command echo "$_co_sess — ESCALATION: still $_co_detail after $GOLEM_MODE_FIX_ATTEMPTS attempt(s);" \
                "the keystroke is not sticking — attach with golem-attach.sh $_co_n"
            _co_rc=1
        fi
    done

    return "$_co_rc"
}

# require_tmux — fail LOUD when tmux is absent. Reporting "no drift" because we
# could not look is indistinguishable from a working check.
require_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        command echo "golem-mode-check: tmux not found on PATH — cannot read golem pane modes." >&2
        command echo "  This check needs tmux to classify each golem's permission mode; refusing" >&2
        command echo "  to report 'no drift' when it could not look. Install tmux or run this on the host." >&2
        return 2
    fi
    return 0
}

usage() {
    command cat >&2 <<'EOF'
usage: golem-mode-check.sh [--once|--watch] [--fix] [--interval S]
       golem-mode-check.sh verify-send <N|golem-N> <keys...>

  Detect golems left in plan mode past their planning phase (#659), and with
  --fix correct them (bounded by GOLEM_MODE_FIX_ATTEMPTS, verified by re-scrape).

  verify-send sends keystrokes to a golem and confirms the pane actually changed
  — a send to a golem with a modal open is silently swallowed.
EOF
}

# --- drive ------------------------------------------------------------------
# Main-guard so the tests can SOURCE this file to unit-test the matchers and
# phase helpers in isolation without running the drive (mirrors
# golem-status.sh:1031 / golem-resolve.sh:120 / golem-gate-watch.sh:842).
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

watch=0
fix=0
interval=""

# `verify-send` is a subcommand, not a flag — handle it before the flag loop.
if [ "${1:-}" = "verify-send" ]; then
    shift
    if [ "$#" -lt 2 ]; then
        command echo "golem-mode-check: verify-send needs <N|golem-N> and at least one key" >&2
        exit 2
    fi
    require_tmux || exit 2
    vs_arg="$1"
    shift
    case "$vs_arg" in
        golem-*) vs_sess="$vs_arg" ;;
        *) vs_sess="golem-$vs_arg" ;;
    esac
    case "$vs_sess" in
        *[!A-Za-z0-9_.-]*)
            command echo "golem-mode-check: invalid golem id '$vs_arg'" >&2
            exit 2
            ;;
    esac
    # Confirm the pane simply CHANGED — the generic swallowed-send guard, with no
    # opinion about what the keys were meant to do.
    vs_before="$(tmux capture-pane -p -t "$vs_sess" 2>/dev/null || true)"
    _expect_changed() { [ "$1" != "$vs_before" ]; }
    if verify_send "$vs_sess" _expect_changed "$@"; then
        command echo "$vs_sess — send confirmed (pane changed)"
        exit 0
    fi
    command echo "$vs_sess — SEND NOT CONFIRMED: the pane did not change." >&2
    command echo "  A send to a golem with a permission modal open is silently swallowed —" >&2
    command echo "  the keys never reach the transcript. Attach and check: golem-attach.sh ${vs_sess#golem-}" >&2
    exit 1
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --once) watch=0 ;;
        --watch) watch=1 ;;
        --fix) fix=1 ;;
        --interval)
            [ "$#" -ge 2 ] || {
                command echo "golem-mode-check: --interval needs a value (seconds)" >&2
                exit 2
            }
            interval="$2"
            shift
            ;;
        -h | --help | help)
            usage
            exit 0
            ;;
        *)
            command echo "golem-mode-check: unknown argument '$1' (want [--once|--watch] [--fix] [--interval S])" >&2
            exit 2
            ;;
    esac
    shift
done

require_tmux || exit 2

[ -n "$interval" ] || interval="$GOLEM_MODE_CHECK_INTERVAL"
case "$interval" in
    '' | *[!0-9]* | 0)
        command echo "golem-mode-check: --interval must be a positive integer, got '$interval'" >&2
        exit 2
        ;;
esac

if [ "$watch" -eq 0 ]; then
    check_once "$fix"
    exit $?
fi

command echo "Mode-drift check every ${interval}s (fix=$fix). Ctrl-C to stop." >&2
while :; do
    check_once "$fix" || true
    "$SLEEP" "$interval"
done
