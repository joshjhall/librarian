# shellcheck shell=bash
# golem-handoff-relaunch.sh — golem helper-script tests (#1057).
#
# The relaunch is the orchestrator's half of a context handoff: a golem that
# read `verdict=handoff` writes its checkpoint and ends its turn, but cannot exit
# its own process, so nothing started the fresh session. These cases pin the
# four-signal detection (each signal must be able to VETO on its own) and the
# relaunch's delivery: `/clear` and the resume command as two SEPARATE confirmed
# sends, in that order, and never a second time for the same handoff.
#
# Sourced by tests/validate-golem-scripts.sh, which defines HANDOFF_RELAUNCH /
# REAL_BASH / GIT_SCRUB and sources tests/lib/golem-sandbox.sh first. This
# fragment only DEFINES test functions.

# A turn that ended on plain text — golem-transcript-liveness classifies it
# `idle` — whose usage puts the context past the default 175k threshold. One
# transcript feeds BOTH context-budget.sh and the liveness read, exactly as a
# real golem's does.
_HR_IDLE_HANDOFF='{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}
{"type":"assistant","isSidechain":false,"message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"checkpoint written; ending turn"}],"usage":{"input_tokens":100,"cache_read_input_tokens":200000}}}'

# Same shape, but under the threshold.
_HR_IDLE_OK='{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}
{"type":"assistant","isSidechain":false,"message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":100,"cache_read_input_tokens":50000}}}'

# Past the threshold, but a tool call is in flight — `working`, not idle.
_HR_WORKING_HANDOFF='{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}
{"type":"assistant","isSidechain":false,"message":{"id":"m1","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Edit"}],"usage":{"input_tokens":100,"cache_read_input_tokens":200000}}}'

# The REAL handoff shape (#1057's own handoff, transcript 62561396…, tail
# reduced to its structural fields — ids, roles, stop_reasons, block types and
# tool names kept verbatim, payloads dropped). The handoff turn runs
# context-budget.sh (Bash) and writes the checkpoint (Write), then ends on text.
# golem-transcript-liveness.sh reads this as "turn ended after a
# background-capable tool" and exits 2 — the case the relaunch exists for.
_HR_HANDOFF_WRITE_TAIL='{"type":"user","isSidechain":false,"message":{"role":"user","content":"/workflow:next-issue 42 --level 3"}}
{"type":"assistant","isSidechain":false,"message":{"id":"msg_011CfgEnWVpjz1f5JyRfBqdq","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_w","name":"Write"}],"usage":{"input_tokens":2,"cache_read_input_tokens":233000}}}
{"type":"assistant","isSidechain":false,"message":{"id":"msg_011CfgEnWVpjz1f5JyRfBqdq","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_b","name":"Bash"}],"usage":{"input_tokens":2,"cache_read_input_tokens":233000}}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_w","type":"tool_result","is_error":false}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_b","type":"tool_result","is_error":false}]}}
{"type":"assistant","isSidechain":false,"message":{"id":"msg_011CfgFTvZm2mAN4t2dy5FAX","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking"}],"usage":{"input_tokens":2,"cache_read_input_tokens":236265,"cache_creation_input_tokens":1463}}}
{"type":"assistant","isSidechain":false,"message":{"id":"msg_011CfgFTvZm2mAN4t2dy5FAX","role":"assistant","stop_reason":"end_turn","content":[{"type":"text"}],"usage":{"input_tokens":2,"cache_read_input_tokens":236265,"cache_creation_input_tokens":1463}}}'

# Pane fixtures for the overlay guard (printf formats: octal escapes expand). An
# idle composer, then one overlay per matcher in pane_has_gate. Each carries ONE
# matcher's signature only — no shared `Enter to select` footer — so dropping any
# single matcher fails a case instead of being covered by a sibling.
_HR_PANE_IDLE='work output\n\n\342\235\257\302\240\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n'
_HR_PANE_PLAN_GATE='work output\n Here is Claude'"'"'s plan:\n Would you like to proceed?\n > 1. Yes, and use auto mode\n   2. No, keep planning\n'
_HR_PANE_PERMISSION_GATE='work output\n Bash command: git push\n Do you want to proceed?\n > 1. Yes\n   2. No\n'
_HR_PANE_QUESTION_GATE='work output\n Which approach?\n > 1. A\n   2. B\n Enter to select\n'

# plant_pane_tmux <sandbox> <printf-fmt> — a capture-only tmux stub (check is
# read-only, so send-keys is logged but never expected).
plant_pane_tmux() {
    local sb="$1" fmt="$2"
    command mkdir -p "$sb/bin"
    # shellcheck disable=SC2059 # the fixture IS a printf format (octal escapes)
    command printf "$fmt" >"$sb/pane.txt"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    capture-pane) command cat "$sb/pane.txt" ;;
    send-keys) printf '%s\n' "\$*" >>"$sb/send-keys.log" ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# _hr_golem <sandbox> <N> <transcript> [state-json] — a golem worktree dir with a
# transcript and (optionally) its next-issue-{N}.json.
_hr_golem() {
    local sb="$1" n="$2" body="$3" state="${4:-}"
    local wt="$sb/.worktrees/issue-$n"
    command mkdir -p "$wt/.claude/memory/tmp"
    plant_transcript "$sb" "$n" "$body"
    if [ -n "$state" ]; then
        command printf '%s\n' "$state" >"$wt/.claude/memory/tmp/next-issue-$n.json"
    fi
}

# A state file whose checkpoint carries an UNRESUMED handoff marker.
_hr_state_open() {
    command printf '{"version":2,"issue":%s,"phase":"implement","autonomy_level":3,"checkpoint":{"completed_phase":"implement","next_action":"x","handoff_marker":{"context_tokens":200100,"threshold":175000,"floor":104000,"pct_of_threshold":114,"at":"2026-10-03T12:00:00Z","r_measured":null}}}' "$1"
}

# plant_relaunch_tmux <sandbox> [fail-on] — a tmux stub whose composer empties on
# every Enter (a healthy golem), logging each send so the ORDER and SEPARATION of
# the two directives can be asserted. With <fail-on>, a literal payload
# containing that text is typed but its Enter never submits — the composer stays
# occupied, so verify-text reports the send as not landed.
plant_relaunch_tmux() {
    local sb="$1" fail_on="${2:-}"
    command mkdir -p "$sb/bin"
    command printf 'work output\n\n\342\235\257\302\240\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$sb/pane.txt"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
    capture-pane) command cat "$sb/pane.txt" ;;
    send-keys)
        printf '%s\n' "\$*" >>"$sb/send-keys.log"
        case "\$*" in
            *-l*)
                : >"$sb/stuck"
                case "\$*" in *"$fail_on"*) [ -n "$fail_on" ] && printf x >"$sb/stuck" ;; esac
                printf 'work output\n\n\342\235\257\302\240typed\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$sb/pane.txt" ;;
            *Enter*)
                [ -s "$sb/stuck" ] || printf 'work output\n\n\342\235\257\302\240\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$sb/pane.txt" ;;
        esac
        ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# run_relaunch <sandbox> <args...> — invoke the script inside the sandbox with
# the fake projects base and the stub tmux on PATH. GOLEM_ID is scrubbed so a
# suite running inside a live golem cannot leak its identity in.
run_relaunch() {
    local sb="$1"
    shift
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV -uGOLEM_ID \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$HANDOFF_RELAUNCH" "$@" 2>&1)" || RUN_RC=$?
}

_hr_need_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    skip_test "jq not available (handoff relaunch needs jq)"
    return 1
}

# --- detection: all four signals -> due --------------------------------------

test_relaunch_check_due_when_all_signals_hold() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_HANDOFF" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_exit 0 "$RUN_RC" "check exits 0"
    assert_contains "$RUN_OUT" "state=due" "handoff + open marker + idle is due"
}

# --- each signal vetoes on its own ------------------------------------------

test_relaunch_not_due_under_threshold() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_OK" "$(_hr_state_open 42)"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "an ok budget is not due"
    assert_contains "$RUN_OUT" "budget verdict is ok" "and says why"
}

# The load-bearing veto: a large golem parked at a HUMAN gate is handoff + idle
# too. Without the marker it must not be cleared — that would destroy the gate.
test_relaunch_not_due_without_handoff_marker() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_HANDOFF" \
        '{"version":2,"issue":42,"phase":"plan","autonomy_level":3,"checkpoint":{"completed_phase":"plan","next_action":"await approval"}}'
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "a large idle golem with no marker is not due"
    assert_contains "$RUN_OUT" "no checkpoint.handoff_marker" "the reason names the missing marker"
}

test_relaunch_not_due_when_marker_already_resumed() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_HANDOFF" \
        '{"version":2,"issue":42,"phase":"implement","autonomy_level":3,"checkpoint":{"handoff_marker":{"at":"2026-10-03T12:00:00Z","r_measured":3}}}'
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "a resumed marker is not due"
    assert_contains "$RUN_OUT" "already resumed" "and says why"
}

test_relaunch_not_due_when_working() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_WORKING_HANDOFF" "$(_hr_state_open 42)"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "a working golem is not due"
    assert_contains "$RUN_OUT" "golem is working" "and says why"
}

# --- unreadable signals are UNKNOWN, never not-due and never due ------------

test_relaunch_unknown_when_no_transcript() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/issue-42/.claude/memory/tmp"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=unknown" "an unreadable budget is unknown"
    assert_contains "$RUN_OUT" "context-budget.sh exit 2" "the reason carries the exit code"
}

test_relaunch_unknown_when_no_worktree() {
    local sb
    new_sandbox sb
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=unknown" "a missing worktree is unknown"
}

test_relaunch_rejects_bad_args() {
    local sb
    new_sandbox sb
    run_relaunch "$sb" check 4x2
    assert_exit 2 "$RUN_RC" "a non-numeric issue is a usage error"
    run_relaunch "$sb" frobnicate 42
    assert_exit 2 "$RUN_RC" "an unknown subcommand is a usage error"
}

# --- relaunch delivery --------------------------------------------------------

# /clear and the resume command go out as two SEPARATE literal sends, /clear
# first, each followed by its own submit — and the level is read from the state
# file, not defaulted.
test_relaunch_sends_clear_then_resume() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_HANDOFF" "$(_hr_state_open 42)"
    plant_relaunch_tmux "$sb"
    run_relaunch "$sb" relaunch 42
    assert_exit 0 "$RUN_RC" "a due golem relaunches"
    local log first second
    log="$(command cat "$sb/send-keys.log" 2>/dev/null)"
    first="$(command printf '%s\n' "$log" | command grep -n -e '-l -- /clear' | command cut -d: -f1)"
    second="$(command printf '%s\n' "$log" | command grep -n -e '-l -- /workflow:next-issue 42 --level 3' | command cut -d: -f1)"
    assert_not_empty "$first" "/clear was sent as a literal payload"
    assert_not_empty "$second" "the resume command was sent with the state file's level"
    assert_true "[ \"${first:-0}\" -lt \"${second:-0}\" ]" "/clear goes out before the resume"
    assert_true "[ -f \"$sb/.worktrees/.status/handoff-relaunched-golem-42\" ]" "the relaunch is stamped"
}

# Idempotence: a second sweep before the fresh session's first request must not
# re-send — typing /clear into the freshly resumed session would wipe it.
test_relaunch_is_idempotent_per_handoff() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_HANDOFF" "$(_hr_state_open 42)"
    plant_relaunch_tmux "$sb"
    run_relaunch "$sb" relaunch 42
    assert_exit 0 "$RUN_RC" "first relaunch succeeds"
    command rm -f "$sb/send-keys.log"
    run_relaunch "$sb" relaunch 42
    assert_exit 1 "$RUN_RC" "a second relaunch for the same handoff is refused"
    assert_contains "$RUN_OUT" "already relaunched" "and says why"
    assert_true "[ ! -s \"$sb/send-keys.log\" ]" "nothing was sent the second time"
}

# A not-due golem is never typed into.
test_relaunch_sends_nothing_when_not_due() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_OK" "$(_hr_state_open 42)"
    plant_relaunch_tmux "$sb"
    run_relaunch "$sb" relaunch 42
    assert_exit 1 "$RUN_RC" "relaunch of a not-due golem exits 1"
    assert_true "[ ! -s \"$sb/send-keys.log\" ]" "no keys were sent"
}

# --- the real handoff shape: turn ended on Write/Bash (operator gap, #1057) ---

# Liveness is indeterminate (exit 2, #890) for EVERY handoff, because the
# handoff turn ends on Bash + Write. The open marker disambiguates it; with an
# idle pane the golem is due. Before the fix this read state=unknown forever.
test_relaunch_due_on_real_handoff_tail_ending_in_write() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=due" "a real handoff tail + open marker + idle pane is due"
    assert_contains "$RUN_OUT" "marker disambiguates" "the reason names the disambiguation"
}

# The same tail WITHOUT a marker stays unknown: the #890 indeterminate is only
# resolved by the golem's own statement that it handed off.
test_relaunch_unknown_on_write_tail_without_marker() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" \
        '{"version":2,"issue":42,"phase":"implement","autonomy_level":3,"checkpoint":{"completed_phase":"implement","next_action":"x"}}'
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "no marker vetoes before liveness is consulted"
    assert_not_contains "$RUN_OUT" "state=due" "never due without the marker"
}

# Human-gate safety: an open marker AND a gate overlay on the pane must never be
# cleared — for every overlay kind, on the disambiguated path and on the
# plain-idle path alike.
test_relaunch_not_due_when_pane_shows_plan_gate() {
    _hr_need_jq || return 0
    local sb body pane
    for pane in "$_HR_PANE_PLAN_GATE" "$_HR_PANE_PERMISSION_GATE" "$_HR_PANE_QUESTION_GATE"; do
        for body in "$_HR_HANDOFF_WRITE_TAIL" "$_HR_IDLE_HANDOFF"; do
            new_sandbox sb
            _hr_golem "$sb" 42 "$body" "$(_hr_state_open 42)"
            plant_pane_tmux "$sb" "$pane"
            run_relaunch "$sb" relaunch 42
            assert_exit 1 "$RUN_RC" "a golem showing a gate overlay is not relaunched"
            assert_contains "$RUN_OUT" "prompt overlay" "the reason names the overlay"
            assert_true "[ ! -s \"$sb/send-keys.log\" ]" "no keys were sent over a human gate"
        done
    done
}

# The overlay check is a safety guard, so an unreadable pane is UNKNOWN — never a
# pass — on BOTH liveness paths, and nothing is sent or stamped.
test_relaunch_unknown_when_pane_unreadable() {
    _hr_need_jq || return 0
    local sb body
    for body in "$_HR_HANDOFF_WRITE_TAIL" "$_HR_IDLE_HANDOFF"; do
        new_sandbox sb
        _hr_golem "$sb" 42 "$body" "$(_hr_state_open 42)"
        command mkdir -p "$sb/bin"
        command printf '#!/usr/bin/env bash\nexit 1\n' >"$sb/bin/tmux"
        command chmod +x "$sb/bin/tmux"
        run_relaunch "$sb" relaunch 42
        assert_contains "$RUN_OUT" "state=unknown" "an unreadable pane is unknown on every liveness path"
        assert_contains "$RUN_OUT" "pane unreadable" "and says why"
        assert_true "[ ! -e \"$sb/.worktrees/.status/handoff-relaunched-golem-42\" ]" "nothing was stamped"
    done
}

# Registered background work still vetoes: liveness reads it as `background`
# (exit 0) before the #890 arm, so the disambiguation never reaches it.
test_relaunch_not_due_on_write_tail_with_background_work() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    plant_work_registry "$sb" golem-42 "$(work_register_line w1 workflow review "$(date +%s)")"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "open background work is not due"
    assert_contains "$RUN_OUT" "golem is background" "and says why"
}

# Only the #890 turn-ended shape is disambiguated. A DIFFERENT indeterminate — a
# stale `working` transcript (the process likely died mid tool-call) — stays
# unknown even with an open marker and an idle pane.
test_relaunch_unknown_on_other_indeterminate_with_marker() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_WORKING_HANDOFF" "$(_hr_state_open 42)"
    command touch -t 200001010000 "$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=unknown" "a stale-working indeterminate is unknown, marker or not"
    assert_contains "$RUN_OUT" "exit 2" "the reason carries the liveness exit code"
}

# The overlay matchers live in golem-gate-watch.sh. If it cannot load, the gate
# check must answer "gate" (refuse), never "no gate" — run a scripts copy with it
# removed, against an idle pane that would otherwise be due.
test_relaunch_refuses_when_gate_matchers_unavailable() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    command cp -R "$(command dirname "$HANDOFF_RELAUNCH")" "$sb/scripts-copy"
    command rm -f "$sb/scripts-copy/golem-gate-watch.sh"
    local HANDOFF_RELAUNCH="$sb/scripts-copy/golem-handoff-relaunch.sh"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "missing gate matchers refuse"
    assert_contains "$RUN_OUT" "prompt overlay" "by treating the pane as gated"
}

# --- delivery failures and the half-relaunch (#1057 review) ------------------

# A /clear that never lands must not be followed by the resume, and leaves no
# stamp — the next sweep sees the same `due` golem and retries cleanly.
test_relaunch_clear_not_confirmed_sends_no_resume() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_relaunch_tmux "$sb" "/clear"
    run_relaunch "$sb" relaunch 42
    assert_exit 1 "$RUN_RC" "an unconfirmed /clear fails the relaunch"
    assert_contains "$RUN_OUT" "/clear not confirmed" "and says which send failed"
    assert_not_contains "$(command cat "$sb/send-keys.log" 2>/dev/null)" "next-issue" "the resume was never sent"
    assert_true "[ ! -e \"$sb/.worktrees/.status/handoff-relaunched-golem-42\" ]" "nothing was stamped"
}

# /clear lands, the resume does not: the golem is cleared, so its budget now
# reads ok. The `cleared <at>` stamp must surface it as resume-due, and the next
# relaunch sends ONLY the resume — a second /clear would wipe nothing useful but
# a resumed session is exactly what it must never hit.
test_relaunch_half_relaunch_is_resume_due() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_relaunch_tmux "$sb" "next-issue"
    run_relaunch "$sb" relaunch 42
    assert_exit 1 "$RUN_RC" "an unconfirmed resume fails the relaunch"
    assert_contains "$RUN_OUT" "resume-due" "the failure names the recovery state"
    assert_equals "cleared 2026-10-03T12:00:00Z" "$(command cat "$sb/.worktrees/.status/handoff-relaunched-golem-42" 2>/dev/null)" "the half-relaunch is stamped"
    # The cleared session now reads near the floor — an `ok` budget.
    _hr_golem "$sb" 42 "$_HR_IDLE_OK" "$(_hr_state_open 42)"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=resume-due" "an ok budget does not hide the stranded golem"
    plant_relaunch_tmux "$sb"
    command rm -f "$sb/send-keys.log"
    run_relaunch "$sb" relaunch 42
    assert_exit 0 "$RUN_RC" "the resume-only relaunch succeeds"
    assert_not_contains "$(command cat "$sb/send-keys.log" 2>/dev/null)" "/clear" "no second /clear"
    assert_contains "$(command cat "$sb/send-keys.log" 2>/dev/null)" "-l -- /workflow:next-issue 42 --level 3" "the resume is sent"
    assert_equals "2026-10-03T12:00:00Z" "$(command cat "$sb/.worktrees/.status/handoff-relaunched-golem-42" 2>/dev/null)" "the stamp completes"
}

# A half-relaunch is still behind the overlay guard, and stops once the fresh
# session has resumed (r_measured set).
test_relaunch_resume_due_respects_gate_and_resume() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_IDLE_OK" "$(_hr_state_open 42)"
    command mkdir -p "$sb/.worktrees/.status"
    command printf 'cleared 2026-10-03T12:00:00Z\n' >"$sb/.worktrees/.status/handoff-relaunched-golem-42"
    plant_pane_tmux "$sb" "$_HR_PANE_PERMISSION_GATE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "prompt overlay" "a gate vetoes the resume-only send too"
    _hr_golem "$sb" 42 "$_HR_IDLE_OK" \
        '{"version":2,"issue":42,"phase":"implement","autonomy_level":3,"checkpoint":{"handoff_marker":{"at":"2026-10-03T12:00:00Z","r_measured":3}}}'
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=not-due" "a resumed marker ends the half-relaunch"
}

# The stamp is keyed on `at`: a LATER handoff for the same golem relaunches.
test_relaunch_new_handoff_after_stamped_one_is_due() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    command mkdir -p "$sb/.worktrees/.status"
    command printf '2026-09-30T08:00:00Z\n' >"$sb/.worktrees/.status/handoff-relaunched-golem-42"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=due" "a stamp for an older handoff does not block a new one"
}

# An empty `at` cannot key the stamp — unknown, not a permanent match.
test_relaunch_unknown_when_marker_has_no_at() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" \
        '{"version":2,"issue":42,"phase":"implement","autonomy_level":3,"checkpoint":{"handoff_marker":{"context_tokens":200100,"r_measured":null}}}'
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=unknown" "a marker with no at is unknown"
    assert_contains "$RUN_OUT" "no 'at' timestamp" "and says why"
}

# A `cleared A` stamp the script never completed (the resume was typed by hand,
# or verify-text missed a submit that landed) must not strand the golem's NEXT
# handoff B: the stale stamp falls through to normal detection, which is due.
test_relaunch_stale_cleared_stamp_does_not_strand_new_handoff() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 "$_HR_HANDOFF_WRITE_TAIL" "$(_hr_state_open 42)"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    command mkdir -p "$sb/.worktrees/.status"
    command printf 'cleared 2026-09-30T08:00:00Z\n' >"$sb/.worktrees/.status/handoff-relaunched-golem-42"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=due" "a stale cleared stamp falls through to the new handoff"
    assert_not_contains "$RUN_OUT" "resume-due" "and is not mistaken for a half-relaunch"
}

# resume-due must never type into a session that is already working: the resume
# arrived by another route, so the half-relaunch is over.
test_relaunch_resume_due_refuses_a_working_session() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 '{"type":"user","isSidechain":false,"message":{"role":"user","content":"/workflow:next-issue 42 --level 3"}}
{"type":"assistant","isSidechain":false,"message":{"id":"m1","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read"}],"usage":{"input_tokens":100,"cache_read_input_tokens":30000}}}' "$(_hr_state_open 42)"
    command mkdir -p "$sb/.worktrees/.status"
    command printf 'cleared 2026-10-03T12:00:00Z\n' >"$sb/.worktrees/.status/handoff-relaunched-golem-42"
    plant_relaunch_tmux "$sb"
    run_relaunch "$sb" relaunch 42
    assert_exit 1 "$RUN_RC" "a working cleared session is not relaunched"
    assert_contains "$RUN_OUT" "resumed by another route" "and says why"
    assert_true "[ ! -s \"$sb/send-keys.log\" ]" "nothing was typed into the live session"
}

# The freshly-cleared session holds only the /clear record — liveness reads "no
# top-level turn" (exit 2). That one indeterminate is the expected half-relaunch
# shape and stays resume-due.
test_relaunch_resume_due_on_fresh_cleared_transcript() {
    _hr_need_jq || return 0
    local sb
    new_sandbox sb
    _hr_golem "$sb" 42 '{"type":"system","isSidechain":false,"subtype":"local_command","content":"/clear"}' "$(_hr_state_open 42)"
    command mkdir -p "$sb/.worktrees/.status"
    command printf 'cleared 2026-10-03T12:00:00Z\n' >"$sb/.worktrees/.status/handoff-relaunched-golem-42"
    plant_pane_tmux "$sb" "$_HR_PANE_IDLE"
    run_relaunch "$sb" check 42
    assert_contains "$RUN_OUT" "state=resume-due" "a session holding only /clear is resume-due"
}
