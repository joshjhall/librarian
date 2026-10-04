#!/usr/bin/env bash
# golem-handoff-relaunch.sh — start the fresh session a context handoff asks for
# (issue #1057).
#
# THE GAP IT CLOSES. A golem that reads `verdict=handoff` from context-budget.sh
# writes its checkpoint and ends its turn (next-issue/handoff-protocol.md). But a
# model cannot exit its own `claude` process, so "end the session" leaves the
# process idle at its prompt — and the launch line's `; claude
# '/workflow:ship-issue'` tail only runs on process EXIT. monitor-protocol.md
# expected a fresh session to follow a `HANDOFF DUE` row; nothing created one.
# The verdict was honored and the golem then sat idle at 400k forever.
#
# The relaunch is the orchestrator's half: detect a golem that has handed off
# and is idle, then send `/clear` and the resume command over the same directed
# send-keys path every other brokered keystroke uses.
#
# DETECTION NEEDS FOUR SIGNALS, AND EACH IS LOAD-BEARING:
#
#   1. budget verdict == handoff   — context-budget.sh, never re-derived here.
#   2. an UNRESUMED handoff_marker — the golem's next-issue-{N}.json carries
#      checkpoint.handoff_marker with r_measured == null. This is the golem's own
#      statement "I checkpointed for a handoff", and the only signal that tells a
#      handed-off golem from one that is merely large and parked at a HUMAN gate
#      (a plan-approval prompt at 200k is `handoff` + `idle` too). Clearing that
#      golem would destroy an unanswered gate — far worse than not relaunching.
#   3. liveness == idle            — golem-transcript-liveness.sh. Anything else
#      (working, background, errored, indeterminate) is not a handoff the golem
#      finished acting on; a `/clear` typed over live work would discard it.
#      ONE indeterminate shape is accepted, because (2) disambiguates it: "turn
#      ended after a background-capable tool" (#890). A handoff turn ALWAYS ends
#      that way — it runs context-budget.sh (Bash) and writes the checkpoint — so
#      requiring a plain `idle` made the relaunch unreachable for exactly the
#      case it exists for (measured on #1057's own handoff: liveness exit 2,
#      tools Bash,EnterPlanMode,ExitPlanMode,Write). The open marker is the
#      golem's own word that it stopped on purpose, and registered background
#      work still reads `background` (exit 0) before that arm, so it still vetoes.
#      Every OTHER indeterminate (stale `working`, no top-level turn) stays
#      unknown.
#   +  no prompt overlay on the pane — a plan/permission/AskUserQuestion modal
#      means a human gate is open, and `/clear` would destroy it. An UNREADABLE
#      pane is unknown, never a pass, on every path: this is a safety guard, and
#      the pane is the only witness to a gate the transcript cannot show.
#   4. not already relaunched      — a stamp keyed on the marker's `at`. After
#      `/clear` the fresh session's transcript is newer and reads near the floor,
#      so (1) normally clears on its own; the stamp covers the window before the
#      fresh session's first request lands, and stops a second sweep re-sending.
#
# HALF-RELAUNCH. If `/clear` lands and the resume does not, the cleared session
# reads near the floor, (1) says `ok`, and every later sweep would call the golem
# not-due — stranded, its handoff never resumed. So the stamp is written as
# `cleared <at>` BEFORE the resume is sent, and checked FIRST: a `cleared` stamp
# whose marker is still open is `resume-due`, and relaunch then sends ONLY the
# resume (never a second `/clear`), still behind the overlay guard.
#
# Each missing signal reports WHY on stdout (`state=…`), so an operator reading a
# sweep can tell "not due" from "could not tell" — a reading that did not happen
# is never rendered as a pass (handoff-protocol.md § fail-loud).
#
# Subcommands:
#   check <N>      read-only. Prints `golem=golem-N`, `state=<s>`, `reason=…`.
#                  state is one of:
#                    due        all four signals hold — relaunch is warranted
#                    resume-due `/clear` landed, the resume did not — send it
#                    not-due    a signal says no (reason names which)
#                    unknown    a signal could not be read (reason names which)
#                  Exit 0 for every state; non-zero only on a usage error.
#   relaunch <N>   check, and when `due`: send `/clear`, then
#                  `/workflow:next-issue N --level L` (L from the state file),
#                  each via `golem-mode-check.sh verify-text`, and write the stamp.
#                  Exit 0 relaunched · 1 not due / not delivered · 2 usage/env.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_STATUS_DIR (.worktrees/.status)
#
# Runtime policy: bash-3.2 clean, `set -uo pipefail` (errors handled per call),
# no GNU-only flags — see CLAUDE.md § Runtime policy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

ctxbudget="$SCRIPT_DIR/context-budget.sh"
liveness="$SCRIPT_DIR/golem-transcript-liveness.sh"
modecheck="$SCRIPT_DIR/golem-mode-check.sh"

usage() {
    command cat >&2 <<'EOF'
usage: golem-handoff-relaunch.sh check <N>
       golem-handoff-relaunch.sh relaunch <N>

  Detect a golem that acted on a context-budget handoff and is idle at its
  prompt, and (relaunch) start its fresh session: /clear, then
  /workflow:next-issue N --level L, each confirmed via verify-text (#1057).
EOF
}

# _kv <text> <key> — the value of a `key=value` line, or empty.
_kv() {
    command printf '%s\n' "$1" | command sed -n "s/^$2=//p" | command head -n 1
}

# pane_has_gate <pane-text> — 0 when a human-gate modal is painted. Delegates to
# golem-gate-watch.sh's footer-anchored matchers (sourced lazily; it is
# main-guarded) so the overlay vocabulary has ONE owner. A gate-watch that cannot
# load answers "gate": the caller then refuses, which is the safe direction.
pane_has_gate() {
    if [ "${_HR_GATE_WATCH_LOADED:-0}" != "1" ]; then
        # shellcheck source=./golem-gate-watch.sh
        . "$SCRIPT_DIR/golem-gate-watch.sh" 2>/dev/null || return 0
        _HR_GATE_WATCH_LOADED=1
    fi
    pane_is_plan_gate "$1" && return 0
    pane_is_gate "$1" && return 0
    pane_is_multi_question_form "$1" && return 0
    pane_is_fork "$1" && return 0
    return 1
}

# _check_pane — the overlay guard. Returns 0 when the pane is readable and shows
# no gate; otherwise sets _state/_reason (not-due on a gate, unknown on an
# unreadable pane — fail CLOSED, never a pass) and returns 1.
_check_pane() {
    _pane="$(tmux capture-pane -p -t "golem-$_n" 2>/dev/null || true)"
    if [ -z "$_pane" ]; then
        _reason="pane unreadable (tmux capture-pane golem-$_n) — cannot rule out an open gate"
        return 1
    fi
    if pane_has_gate "$_pane"; then
        _state="not-due"
        _reason="pane shows a prompt overlay (plan/permission/question gate) — never cleared"
        return 1
    fi
    return 0
}

# _detect_half <at> — a `cleared <at>` stamp: /clear landed, the resume may not
# have. The budget is no longer a signal (the cleared session reads near the
# floor), so this path reads the marker and the pane only.
_detect_half() {
    _at="$1"
    if ! command -v jq >/dev/null 2>&1; then
        _reason="jq not found — cannot read $_sf"
        return 0
    fi
    _marker="$(jq -r '
        (.checkpoint.handoff_marker // null) as $m
        | if ($m | type) != "object" then "none"
          elif ($m.r_measured // null) != null then "resumed"
          else "open\t\($m.at // "")\t\(.autonomy_level // "")"
          end' "$_sf" 2>/dev/null)" || _marker=""
    case "$_marker" in
        resumed)
            _state="not-due"
            _reason="handoff_marker resumed after /clear (r_measured set)"
            return 0
            ;;
        open*) ;;
        *)
            _reason="cleared for handoff at $_at but the state file's marker is unreadable: $_sf"
            return 0
            ;;
    esac
    if [ "$(command printf '%s' "$_marker" | command cut -f2)" != "$_at" ]; then
        _reason="cleared-stamp ($_at) does not match the open marker — attach and check"
        return 0
    fi
    _level="$(command printf '%s' "$_marker" | command cut -f3)"
    case "$_level" in
        1 | 2 | 3 | 4) ;;
        *)
            _reason="state file has no valid autonomy_level ('$_level')"
            return 0
            ;;
    esac
    _check_pane || return 0
    _state="resume-due"
    _reason="/clear landed for handoff at $_at but the resume never did"
}

# detect <N> — set _state / _reason / _level / _at. Never exits.
detect() {
    _n="$1"
    _state="unknown"
    _reason=""
    _level=""
    _at=""
    _wt="$root/$GOLEM_WORKTREE_DIR/issue-$_n"
    _sf="$_wt/.claude/memory/tmp/next-issue-$_n.json"

    if [ ! -d "$_wt" ]; then
        _reason="no worktree at $_wt"
        return 0
    fi

    _stamp="$root/$GOLEM_STATUS_DIR/handoff-relaunched-golem-$_n"
    _stamp_body="$(command cat "$_stamp" 2>/dev/null || true)"
    case "$_stamp_body" in
        "cleared "*)
            _detect_half "${_stamp_body#cleared }"
            return 0
            ;;
    esac

    # (1) budget verdict. The script's own exit code is the fail-loud signal: a
    # non-zero exit is an UNKNOWN budget, never `ok`.
    _cb_rc=0
    _cb="$("$ctxbudget" check "$_wt" 2>/dev/null)" || _cb_rc=$?
    _v="$(_kv "$_cb" verdict)"
    if [ "$_cb_rc" -ne 0 ] || [ -z "$_v" ]; then
        _reason="context budget unreadable (context-budget.sh exit $_cb_rc)"
        return 0
    fi
    if [ "$_v" != "handoff" ]; then
        _state="not-due"
        _reason="budget verdict is $_v"
        return 0
    fi

    # (2) an unresumed handoff marker in the golem's own state file.
    if ! command -v jq >/dev/null 2>&1; then
        _reason="jq not found — cannot read $_sf"
        return 0
    fi
    if [ ! -f "$_sf" ]; then
        _state="not-due"
        _reason="budget is handoff but no state file — golem has not checkpointed"
        return 0
    fi
    _marker="$(jq -r '
        (.checkpoint.handoff_marker // null) as $m
        | if ($m | type) != "object" then "none"
          elif ($m.r_measured // null) != null then "resumed"
          else "open\t\($m.at // "")\t\(.autonomy_level // "")"
          end' "$_sf" 2>/dev/null)" || _marker=""
    case "$_marker" in
        none)
            _state="not-due"
            _reason="budget is handoff but no checkpoint.handoff_marker — golem has not checkpointed (may be parked at a human gate)"
            return 0
            ;;
        resumed)
            _state="not-due"
            _reason="handoff_marker already resumed (r_measured set)"
            return 0
            ;;
        open*) ;;
        *)
            _reason="state file unparsable: $_sf"
            return 0
            ;;
    esac
    _at="$(command printf '%s' "$_marker" | command cut -f2)"
    _level="$(command printf '%s' "$_marker" | command cut -f3)"
    case "$_level" in
        1 | 2 | 3 | 4) ;;
        *)
            _reason="state file has no valid autonomy_level ('$_level')"
            return 0
            ;;
    esac
    # The stamp is keyed on `at`; an empty one would match an empty stamp
    # forever and silence every later handoff.
    if [ -z "$_at" ]; then
        _reason="handoff_marker has no 'at' timestamp — cannot key the relaunch stamp"
        return 0
    fi

    # (3) idle at the prompt. Indeterminate (non-zero) is unknown, not idle —
    # except the #890 turn-ended shape, which the open marker disambiguates (see
    # header). stderr is kept apart from the verdict so the shape can be read.
    _lv_rc=0
    _lv_errf="$(command mktemp "${TMPDIR:-/tmp}/handoff-relaunch.XXXXXX")" || _lv_errf=""
    if [ -z "$_lv_errf" ]; then
        _reason="mktemp failed — cannot read liveness"
        return 0
    fi
    _lv="$("$liveness" "$_wt" 2>"$_lv_errf")" || _lv_rc=$?
    _lv_err="$(command cat "$_lv_errf" 2>/dev/null)"
    command rm -f "$_lv_errf"
    _lv_turn_ended=0
    if [ "$_lv_rc" -eq 2 ]; then
        case "$_lv_err" in
            *"turn ended after a background-capable tool"*) _lv_turn_ended=1 ;;
        esac
    fi
    if [ "$_lv_turn_ended" -ne 1 ]; then
        if [ "$_lv_rc" -ne 0 ] || [ -z "$_lv" ]; then
            _reason="liveness indeterminate (golem-transcript-liveness.sh exit $_lv_rc)"
            return 0
        fi
        if [ "$_lv" != "idle" ]; then
            _state="not-due"
            _reason="golem is $_lv, not idle"
            return 0
        fi
    fi

    # (+) no human gate painted on the pane.
    _check_pane || return 0

    # (4) not already relaunched for this marker.
    if [ -f "$_stamp" ] && [ "$_stamp_body" = "$_at" ]; then
        _state="not-due"
        _reason="already relaunched for handoff at $_at"
        return 0
    fi

    _state="due"
    if [ "$_lv_turn_ended" -eq 1 ]; then
        _reason="handoff verdict + open handoff_marker + turn ended (marker disambiguates #890) + no overlay"
    else
        _reason="handoff verdict + open handoff_marker + idle"
    fi
    return 0
}

# --- drive ------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi
cmd="$1"
n="$2"
case "$cmd" in
    check | relaunch) ;;
    *)
        usage
        exit 2
        ;;
esac
case "$n" in
    '' | *[!0-9]*)
        command echo "golem-handoff-relaunch: issue number must be digits, got '$n'" >&2
        exit 2
        ;;
esac

root="$(repo_root)" || {
    command echo "golem-handoff-relaunch: not inside a git repository" >&2
    exit 2
}

detect "$n"
command printf 'golem=golem-%s\nstate=%s\nreason=%s\n' "$n" "$_state" "$_reason"

[ "$cmd" = "check" ] && exit 0
case "$_state" in
    due | resume-due) ;;
    *) exit 1 ;;
esac

# `/clear` first, then the resume. Each through verify-text, which refuses an
# occupied composer and confirms the submit landed (#974) — a relaunch that
# assumed the keystroke worked would be the silent shape this issue is about.
stamp="$root/$GOLEM_STATUS_DIR/handoff-relaunched-golem-$n"
if ! command mkdir -p "$root/$GOLEM_STATUS_DIR" 2>/dev/null; then
    command echo "golem-handoff-relaunch: cannot create $root/$GOLEM_STATUS_DIR — refusing to /clear without a stamp" >&2
    exit 1
fi
if [ "$_state" = "due" ]; then
    if ! "$modecheck" verify-text "$n" "/clear"; then
        command echo "golem-handoff-relaunch: /clear not confirmed for golem-$n — not sending the resume" >&2
        exit 1
    fi
    # Recorded BEFORE the resume, so a resume that fails is found next sweep as
    # resume-due rather than lost behind an `ok` budget (see HALF-RELAUNCH).
    command printf 'cleared %s\n' "$_at" >"$stamp"
fi
if ! "$modecheck" verify-text "$n" "/workflow:next-issue $n --level $_level"; then
    command echo "golem-handoff-relaunch: resume command not confirmed for golem-$n — next sweep reports resume-due" >&2
    exit 1
fi
command printf '%s\n' "$_at" >"$stamp"
if [ "$_state" = "due" ]; then
    command echo "relaunched golem-$n: /clear + /workflow:next-issue $n --level $_level"
else
    command echo "relaunched golem-$n: resume only (/clear had landed) — /workflow:next-issue $n --level $_level"
fi
exit 0
