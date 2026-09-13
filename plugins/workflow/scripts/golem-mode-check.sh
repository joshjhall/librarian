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
#   golem-mode-check.sh verify-text <N> <text>
#                                          relay a free-text directive to golem-N
#                                          as payload-then-submit, and CONFIRM the
#                                          composer emptied (the unsubmitted guard)
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
# correction: the golem has POSITIVELY landed in a working mode.
#
# Requires `auto` or `accept-edits` rather than merely "not plan". The weaker
# `!= plan` form also accepts `unknown` — the documented "cannot tell" state for
# a pane that has not repainted, a full-screen modal, or a transient overlay
# raised by the keystroke itself. Accepting it would report a correction as
# landed without ever confirming the mode, which is precisely the
# assume-the-keystroke-worked failure this whole check exists to close, and it
# contradicts pane_mode_class's own contract that `unknown` is never a licence
# to assume a golem is fine. An `unknown` read therefore consumes a retry
# instead of ending the loop.
#
# Both accepting modes are correct outcomes: accept-edits clears the #659
# condition just as auto does (edits stop being plan-blocked), so treating it as
# failure would burn the retry budget on an already-fixed golem.
_expect_not_plan() {
    case "$(pane_mode_class "$1")" in
        auto | accept-edits) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Text-directive relay (#974)
# ---------------------------------------------------------------------------

# A brokered FREE-TEXT directive is a different failure from the swallowed send
# above, and verify_send cannot cover it.
#
# MEASURED CAUSE (tmux 3.5a, raw-mode reader behind the pane, logging read()):
# `tmux send-keys -t golem-N "<text>" Enter` delivers the payload and the CR in
# ONE read() — 200 bytes ending \r. The composer's paste heuristic treats a CR
# arriving inside a single input chunk as a newline WITHIN the message rather
# than a submit, so the text sits in the composer and the golem idles until a
# second Enter arrives. Splitting the call delivers the CR as its own 1-byte
# read, which submits. Reproduced at 200 chars, so it is NOT length-dependent
# (tmux does split its own writes above 4095 bytes, but that boundary is
# unrelated), and no bracketed-paste wrapper is ever emitted.
#
# WHY verify_send's PREDICATE IS BLIND TO IT. `_expect_changed` asks only
# whether the pane text differs from before. Typed-but-unsubmitted text SATISFIES
# that — the characters visibly appear in the composer — so verify-send reports
# "send confirmed" for precisely this bug. Asserting the composer went EMPTY is
# the only read that distinguishes "submitted" from "typed"; that is the AC's
# "not merely that the pane changed".
#
# _composer_class <session> — echo empty | input | suggestion | unknown for the
# golem's live composer line.
#
# The classifier is BORROWED, not re-derived: golem-gate-watch.sh's
# pane_prompt_line_class already parses this exact line, and its parse is subtle
# (anchors on the prompt glyph + NBSP PAIR, takes the FIRST occurrence, strips
# SGR — each choice reached by measurement after getting it wrong). A second
# hand-copy of that is the duplication #663 exists to kill.
#
# Sourced LAZILY rather than at file scope, and the real invariant is NARROWER
# than "function scope protects the caller" — that is false, and measured false:
# gate-watch assigns ~20 top-level globals of its own (`interval`, `ttl`,
# `pane_error_lines`, `SLEEP`, `GREP`, `SCRIPT_DIR`, ...), and sourcing from
# inside a function CLOBBERS them in the caller too unless the caller declared
# them `local`. Nothing here does, and the dispatch arms below are top-level
# code, where `local` is not even available. Setting `interval=SENTINEL` before
# the call and reading it after returns gate-watch's `5`, not the sentinel.
#
# What actually makes this safe is control flow, so state it as such:
#   the `verify-text` and `verify-send` arms `exit` immediately after their one
#   use, BEFORE the flag-parsing loop or the watch loop ever read `$interval`.
#
# So: do NOT call _composer_class from a path that afterwards reads `$interval`
# or any other gate-watch top-level name. Doing so would silently pick up
# gate-watch's 5s watch cadence in place of the operator's `--interval` — no
# error, just the wrong number. Lazy sourcing still buys something real (a
# `--once`/`--watch` run never loads gate-watch at all); it is simply not what
# bounds the clobber.
#
# gate-watch is main-guarded, has no side effects at load, and costs ~25ms.
_composer_class() {
    if [ "${_MC_GATE_WATCH_LOADED:-0}" != "1" ]; then
        if [ ! -r "$SCRIPT_DIR/golem-gate-watch.sh" ]; then
            command echo "unknown"
            return 0
        fi
        # shellcheck source=./golem-gate-watch.sh
        . "$SCRIPT_DIR/golem-gate-watch.sh" || {
            command echo "unknown"
            return 0
        }
        _MC_GATE_WATCH_LOADED=1
    fi
    pane_prompt_line_class "$1"
}

# verify_text <session> <text> — relay a free-text directive and CONFIRM it was
# submitted. Returns 0 once the composer is empty, 1 when it never emptied.
#
# The payload goes out with `-l --`: `-l` sends it LITERALLY, so a word like
# "Enter" inside the prose is not resolved as a key name, and `--` ends option
# parsing, so a directive beginning with a dash is not eaten as a tmux flag.
# verify_send passes "$@" through with neither, which is right for `1 Enter` and
# `BTab` and wrong for arbitrary operator text.
#
# TRUST BOUNDARY: the payload must be OPERATOR-AUTHORED text. `-l` stops tmux
# from resolving it as key names, but it does not strip terminal escape
# sequences, and the text is painted into a pane a human later reads over
# golem-attach.sh. Do not pipe untrusted content (an issue or comment body, a
# web fetch) straight into this — filter it first, or relay a summary you wrote.
#
# The submit is retried up to GOLEM_MODE_FIX_ATTEMPTS times — the same bound the
# auto-correct uses — because the observed failure is precisely that the FIRST
# Enter does not take. Bounded-then-escalate, never spin: a submit that will not
# land is a genuine stall and looping keystrokes at it forever is the failure
# mode this script exists to avoid.
verify_text() {
    _vt_sess="$1"
    _vt_text="$2"
    _vt_attempt=0

    # REFUSE to type into an occupied composer. Typing appends, so relaying onto
    # leftover text would submit ONE merged directive — a decision the operator
    # never wrote, delivered confidently. That is strictly worse than the bug
    # being fixed (there the text at least sat visible and unsent), so this is a
    # refusal rather than a clear-and-continue: whatever is already queued is
    # someone's input, and this helper must not silently discard it.
    #
    # `unknown` does NOT block here — the composer is unreadable on a pane that
    # has not repainted, and refusing on it would make the relay unusable exactly
    # when a golem is busy. The submit-side check below is what actually
    # confirms delivery, and it treats `unknown` as a failure.
    #
    # Returns 3, not 1, so the caller can say "nothing was sent" — the generic
    # failure message tells the operator not to re-send the payload, which is
    # exactly the wrong advice when the payload never went out.
    case "$(_composer_class "$_vt_sess")" in
        input | suggestion) return 3 ;;
    esac

    # Payload first, on its own — never combined with the submit.
    tmux send-keys -t "$_vt_sess" -l -- "$_vt_text" 2>/dev/null || return 1
    "$SLEEP" 1

    while [ "$_vt_attempt" -lt "$GOLEM_MODE_FIX_ATTEMPTS" ]; do
        _vt_attempt=$((_vt_attempt + 1))
        tmux send-keys -t "$_vt_sess" Enter 2>/dev/null || return 1
        # Let the pane repaint before re-scraping; a same-instant capture races
        # the redraw and would read the PRE-submit composer, reporting a false
        # "not submitted" for a send that actually worked.
        "$SLEEP" 1
        # `unknown` deliberately consumes a retry rather than passing. It is the
        # documented cannot-tell state (pane not repainted, a modal overlay), and
        # reading it as success would confirm a directive that was never
        # submitted — the assume-the-keystroke-worked failure this whole file
        # exists to close. Same rule as _expect_not_plan above.
        [ "$(_composer_class "$_vt_sess")" = "empty" ] && return 0
    done
    return 1
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
#
# The return code is STICKY-WORST across the fleet, never last-write-wins. A
# single scalar reassigned per golem would let a later golem's clean fix
# overwrite an earlier golem's unresolved escalation, so a sweep that printed an
# ESCALATION line would still exit 0 — the watch loop and any caller keying off
# the exit status would read "all handled" while a golem sat waiting for an
# operator. `_co_unresolved` only ever latches to 1, so one unresolved golem
# anywhere in the sweep decides the result no matter what follows it.
check_once() {
    _co_fix="$1"
    _co_unresolved=0
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

        _co_exp="$(expected_mode "${GOLEM_LEVEL:-4}")"
        _co_detail="in plan mode past the planning phase"
        [ -n "$_co_exp" ] && _co_detail="$_co_detail (expected $_co_exp)"

        if [ "$_co_fix" -eq 0 ]; then
            # Report mode: drift itself is the unresolved condition.
            _co_unresolved=1
            command echo "$_co_sess — DRIFT: $_co_detail — rerun with --fix to correct"
            continue
        fi

        # Bounded auto-correct. Each attempt SENDS then RE-SCRAPES; we never
        # assume the keystroke did what we asked.
        _co_attempt=1
        _co_fixed=0
        while [ "$_co_attempt" -le "$GOLEM_MODE_FIX_ATTEMPTS" ]; do
            # BTab, NOT S-Tab. tmux's traditional key table names shift-tab
            # `BTab` (back-tab); `S-<name>` modifier syntax needs extended-keys
            # support and is silently downgraded otherwise. Measured on tmux
            # 3.5a with `cat -v` behind the pane: `send-keys S-Tab` delivers
            # `^I` — a PLAIN TAB, modifier dropped — while `send-keys BTab`
            # delivers `^[[Z`, the real CSI Z shift-tab. BOTH return rc=0, so the
            # send's exit status cannot distinguish them: S-Tab would have typed
            # a bare Tab into the golem's prompt, never cycling the mode, and the
            # loop would burn every attempt before escalating a golem it could
            # actually have fixed. This is the same "the keystroke did not do
            # what was assumed" trap the check exists to close — which is why the
            # verification below is what catches it rather than the send's rc.
            if verify_send "$_co_sess" _expect_not_plan BTab; then
                report_correction "$_co_sess" \
                    "auto-corrected out of plan mode on attempt $_co_attempt ($_co_detail)"
                _co_fixed=1
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
            # Latch: a later golem's successful fix must NOT clear this.
            _co_unresolved=1
        fi
    done

    return "$_co_unresolved"
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

# resolve_golem_session <N|golem-N> — set _rgs_sess to the tmux session name;
# return 1 (after a loud message) when the id is not a safe session name. Shared
# by the verify-send and verify-text arms so the two cannot drift apart on what
# counts as a valid golem id.
#
# It assigns rather than echoes, and the caller exits: a `$(...)` wrapper would
# run the validation in a SUBSHELL, where an `exit 2` kills only that subshell
# and the parent sails on with an empty session name — a rejected id would then
# be sent to `tmux -t ""`. Assign-and-return keeps the refusal in the one process
# that can act on it.
resolve_golem_session() {
    case "$1" in
        golem-*) _rgs_sess="$1" ;;
        *) _rgs_sess="golem-$1" ;;
    esac
    case "$_rgs_sess" in
        *[!A-Za-z0-9_.-]*)
            command echo "golem-mode-check: invalid golem id '$1'" >&2
            return 1
            ;;
    esac
    return 0
}

usage() {
    command cat >&2 <<'EOF'
usage: golem-mode-check.sh [--once|--watch] [--fix] [--interval S]
       golem-mode-check.sh verify-send <N|golem-N> <keys...>
       golem-mode-check.sh verify-text <N|golem-N> <text>

  Detect golems left in plan mode past their planning phase (#659), and with
  --fix correct them (bounded by GOLEM_MODE_FIX_ATTEMPTS, verified by re-scrape).

  verify-send sends keystrokes to a golem and confirms the pane actually changed
  — a send to a golem with a modal open is silently swallowed.

  verify-text relays a free-text directive: payload and submit as SEPARATE sends
  (combined, the trailing Enter is read as a newline and the text sits unsent),
  confirmed by the composer emptying rather than by the pane merely changing
  (#974). Use it for every brokered text directive.
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
    resolve_golem_session "$vs_arg" || exit 2
    vs_sess="$_rgs_sess"
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

# `verify-text` — the free-text sibling (#974). Same subcommand shape, different
# delivery (payload and submit split) and a different predicate (the composer
# emptied, not merely that the pane changed).
if [ "${1:-}" = "verify-text" ]; then
    shift
    if [ "$#" -ne 2 ]; then
        command echo "golem-mode-check: verify-text needs <N|golem-N> and exactly one <text> argument" >&2
        command echo "  Quote the whole directive as ONE argument: verify-text 7 \"OPERATOR DIRECTIVE ...\"" >&2
        exit 2
    fi
    require_tmux || exit 2
    resolve_golem_session "$1" || exit 2
    vt_sess="$_rgs_sess"
    vt_text="$2"
    if [ -z "$vt_text" ]; then
        command echo "golem-mode-check: verify-text needs a non-empty directive" >&2
        exit 2
    fi
    vt_rc=0
    verify_text "$vt_sess" "$vt_text" || vt_rc=$?
    if [ "$vt_rc" -eq 0 ]; then
        command echo "$vt_sess — directive submitted (composer empty)"
        exit 0
    fi
    if [ "$vt_rc" -eq 3 ]; then
        command echo "$vt_sess — NOT SENT: the composer already holds text." >&2
        command echo "  Typing appends, so relaying now would submit ONE merged directive the" >&2
        command echo "  operator never wrote. Nothing was sent. Attach and clear the prompt," >&2
        command echo "  then retry: golem-attach.sh ${vt_sess#golem-}" >&2
        exit 1
    fi
    command echo "$vt_sess — DIRECTIVE NOT SUBMITTED: the composer did not empty after" >&2
    command echo "  $GOLEM_MODE_FIX_ATTEMPTS submit attempt(s). The text is most likely sitting UNSENT in the" >&2
    command echo "  golem's prompt — it will idle until submitted. Do NOT re-send the payload" >&2
    command echo "  (that would double it). Attach and press Enter: golem-attach.sh ${vt_sess#golem-}" >&2
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
