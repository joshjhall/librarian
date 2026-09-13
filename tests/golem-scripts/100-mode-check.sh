# shellcheck shell=bash
# golem-mode-check.sh — golem helper-script tests (issue #659).
#
# Covers the plan-mode drift check: the footer-anchored mode classifier, the
# two-source phase gate, the bounded auto-correct with post-send verification,
# and the fail-loud posture when tmux is absent.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (MODE_CHECK / ...) and sources tests/lib/golem-sandbox.sh for the shared
# sandbox plumbing (new_sandbox / ...) BEFORE this file. This fragment therefore
# only DEFINES test functions; the entry point dispatches them from its explicit
# ordered run_test list.
#
# THE FIXTURES CARRY REAL GLYPH BYTES. Claude Code's mode footer is led by a
# box-drawing glyph, and the matcher requires it so a bare-words mention in prose
# cannot self-trip. A fixture that wrote the glyph as an escape sequence, or
# omitted it, would never match the matcher and would pass with OR without the
# fix — the escaped-fixture-cannot-self-match trap. So the pane builders below
# emit the literal bytes via printf and a dedicated test asserts the bare-words
# form does NOT match, proving the glyph is load-bearing rather than decorative.

# --- pane fixtures ----------------------------------------------------------

# _pane_footer <mode-line> — a realistic pane: some work output, a prompt, then
# the mode footer as the LAST line (where the matcher's footer window looks).
_pane_footer() {
    command printf 'running the tests\n  ✓ 12 passed\n\n> \n  %s\n' "$1"
}

# The three real footers, with genuine glyph bytes (⏸ = e28fb8, ⏵⏵ = e28fb5 x2).
_footer_plan() { command printf '\342\217\270 plan mode on (shift+tab to cycle)'; }
_footer_auto() { command printf '\342\217\265\342\217\265 auto mode on (shift+tab to cycle)'; }
_footer_accept() { command printf '\342\217\265\342\217\265 accept edits on (shift+tab to cycle)'; }

# plant_mode_tmux <sandbox> <pane-file> — a tmux stub whose `capture-pane` echoes
# the CURRENT contents of <pane-file>, `ls` reports one golem session, and
# `send-keys` appends to a log. Because capture-pane re-reads the file each call,
# a send-keys handler can REWRITE it to simulate the keystroke landing — which is
# what lets the auto-correct's send→re-scrape→confirm loop be tested honestly
# instead of assumed.
#
# <flip-file>, when present, makes the FIRST send-keys rewrite the pane to auto
# mode (the keystroke lands); when absent, send-keys changes nothing (the
# keystroke is swallowed / the mode will not stick).
plant_mode_tmux() {
    local sb="$1" panefile="$2" flip="${3:-}"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
# Test stub: a scriptable tmux for the mode-check tests.
case "\$1" in
    ls) printf 'golem-7: 1 windows\n' ;;
    capture-pane) command cat "$panefile" ;;
    send-keys)
        printf '%s\n' "\$*" >>"$sb/send-keys.log"
        if [ -n "$flip" ] && [ -f "$flip" ]; then
            # The keystroke LANDS: repaint the pane in auto mode.
            printf 'running the tests\n  \342\234\223 12 passed\n\n> \n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$panefile"
            command rm -f "$flip"
        fi
        ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# plant_mode_tmux2 <sandbox> <paneA> <paneB> [flipB] — a two-session variant of
# the stub: `tmux ls` reports golem-7 AND golem-8, and capture-pane dispatches on
# the -t target so each golem has its own independently-controlled pane.
#
# This exists because a single-session stub cannot see a whole CLASS of bug: any
# per-golem outcome that is aggregated across the sweep (the run's exit code
# being the case in point) is trivially correct when there is only ever one
# golem. Only <flipB> is supported — golem-8 is the one that can be made to fix
# cleanly while golem-7 stays stuck, which is exactly the ordering that exposes a
# last-write-wins aggregation.
plant_mode_tmux2() {
    local sb="$1" paneA="$2" paneB="$3" flipB="${4:-}"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
# Test stub: two golem sessions with independent panes.
case "\$1" in
    ls) printf 'golem-7: 1 windows\ngolem-8: 1 windows\n' ;;
    capture-pane)
        case "\$*" in
            *golem-8*) command cat "$paneB" ;;
            *) command cat "$paneA" ;;
        esac
        ;;
    send-keys)
        printf '%s\n' "\$*" >>"$sb/send-keys.log"
        case "\$*" in
            *golem-8*)
                if [ -n "$flipB" ] && [ -f "$flipB" ]; then
                    printf 'work\n\n> \n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$paneB"
                    command rm -f "$flipB"
                fi
                ;;
        esac
        ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# run_mode_check <sandbox> [args...] — invoke golem-mode-check.sh in the sandbox
# with the stub tmux on PATH. Captures RUN_RC / RUN_OUT.
run_mode_check() {
    local sb="$1"
    shift
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            -uBASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=main \
            "$REAL_BASH" "$MODE_CHECK" "$@" 2>&1)" || RUN_RC=$?
}

# _mode_worktree <sandbox> <issue> <commits> [phase] — build a golem worktree for
# issue <N> with <commits> commits beyond base, and optionally a next-issue state
# file recording <phase>. The two phase signals are set INDEPENDENTLY so each arm
# can be tested standing alone.
_mode_worktree() {
    local sb="$1" n="$2" commits="$3" phase="${4:-}"
    local wt="$sb/.worktrees/issue-$n"
    command mkdir -p "$wt"
    (
        cd "$wt" || exit 1
        # -b to PIN the initial branch away from `main`. Without it the branch
        # name comes from the host's init.defaultBranch, and on a host that sets
        # it to `main` (increasingly the default) the `git branch -f main HEAD`
        # below targets the CHECKED-OUT branch and git refuses: "cannot force
        # update the branch 'main' used by worktree at ...". `main` then never
        # moves to the base commit, `main..HEAD` counts 0, and every drift arm
        # silently reports no drift — exit 0 with empty output (#932). CI runners
        # leave init.defaultBranch unset, so this never fired there.
        git init -q -b golem-base .
        git config user.email t@t.t
        git config user.name t
        # commit.gpgsign=false on EVERY commit, matching what golem-sandbox.sh
        # already does for its own fixtures. An operator with global commit
        # signing (`commit.gpgsign=true` + an ssh/gpg agent) otherwise has every
        # commit here REFUSED — e.g. `error: 1Password: agent returned an
        # error` — so HEAD never exists, `git branch -f main HEAD` dies with
        # "not a valid object name", and `main..HEAD` cannot be counted. The
        # drift arms then report exit 0 and empty output, which reads as "no
        # drift detected" rather than "the fixture never built" (#932).
        git -c commit.gpgsign=false commit -q --allow-empty -m base
        git branch -f main HEAD
        local i=0
        while [ "$i" -lt "$commits" ]; do
            git -c commit.gpgsign=false commit -q --allow-empty -m "work $i"
            i=$((i + 1))
        done
    ) >/dev/null 2>&1
    if [ -n "$phase" ]; then
        command mkdir -p "$wt/.claude/memory/tmp"
        command printf '{"version":2,"issue":%s,"phase":"%s"}\n' "$n" "$phase" \
            >"$wt/.claude/memory/tmp/next-issue-$n.json"
    fi
}

# --- mode classifier --------------------------------------------------------

# Source the script (its main-guard returns early) to unit-test the matchers.
_source_mode_check() {
    # shellcheck source=/dev/null
    . "$MODE_CHECK"
}

test_mode_class_plan() {
    local out
    out="$(_source_mode_check && pane_mode_class "$(_pane_footer "$(_footer_plan)")")"
    assert_true "[ '$out' = 'plan' ]" "the plan-mode footer classifies as plan (got '$out')"
}

test_mode_class_auto() {
    local out
    out="$(_source_mode_check && pane_mode_class "$(_pane_footer "$(_footer_auto)")")"
    assert_true "[ '$out' = 'auto' ]" "the auto-mode footer classifies as auto (got '$out')"
}

test_mode_class_accept_edits() {
    local out
    out="$(_source_mode_check && pane_mode_class "$(_pane_footer "$(_footer_accept)")")"
    assert_true "[ '$out' = 'accept-edits' ]" "the accept-edits footer classifies as accept-edits (got '$out')"
}

# A pane with no mode footer is `unknown` — NOT a violation. The honest answer for
# a fresh session or a full-screen modal; treating it as drift would license a
# correction against a golem we cannot even classify.
test_mode_class_unknown_when_no_footer() {
    local out
    out="$(_source_mode_check && pane_mode_class "$(command printf 'just output\nno footer here\n')")"
    assert_true "[ '$out' = 'unknown' ]" "a footerless pane is unknown, not a violation (got '$out')"
}

# GLYPH IS LOAD-BEARING. The bare words "plan mode on" with no glyph — the shape
# that appears in prose, in this repo's own docs, and in golem work output — must
# NOT match. Without this the matcher could drop the glyph requirement and every
# other test here would still pass.
test_mode_class_bare_words_do_not_match() {
    local out
    out="$(_source_mode_check && pane_mode_class "$(_pane_footer 'plan mode on (shift+tab to cycle)')")"
    assert_true "[ '$out' = 'unknown' ]" "bare words without the glyph do not match (got '$out')"
}

# FOOTER ANCHORING (#246/#452). A plan-mode footer sitting in SCROLLBACK, with a
# real auto-mode footer below it, must classify as auto. This is the self-trip
# guard: a golem cat-ing this very file — which necessarily contains these
# phrases — would otherwise be reported as drifted and, under --fix, CORRECTED.
test_mode_class_scrollback_does_not_self_trip() {
    local pane out
    pane="$(
        command printf '  \342\217\270 plan mode on (shift+tab to cycle)\n'
        local i=0
        while [ "$i" -lt 20 ]; do
            command printf 'output line %s\n' "$i"
            i=$((i + 1))
        done
        command printf '  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n'
    )"
    out="$(_source_mode_check && pane_mode_class "$pane")"
    assert_true "[ '$out' = 'auto' ]" \
        "a plan footer in scrollback does not self-trip; the real footer wins (got '$out')"
}

# --- phase gate -------------------------------------------------------------

# THE LOAD-BEARING NEGATIVE. A golem in plan mode that is LEGITIMATELY planning —
# no commits, phase "plan" — is NOT drift and must NOT be corrected. Correcting it
# would kick it out of plan mode mid-design and skip the very gate its level
# exists to enforce, silently turning an L3 run into an L4 one — a worse failure
# than the bug being fixed. Without this case the phase gate is untested and a
# naive footer-only check would pass every other test in this file.
test_mode_planning_golem_is_not_drift() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 0 plan
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once
    assert_exit 0 "$RUN_RC" "a legitimately-planning golem exits 0 (no drift)"
    assert_not_contains "$RUN_OUT" "DRIFT" "a planning golem is not reported as drift"
}

# And the auto-correct must not fire there either — the gate guards BOTH paths.
test_mode_planning_golem_is_not_corrected() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 0 plan
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once --fix
    assert_exit 0 "$RUN_RC" "--fix leaves a planning golem alone (exit 0)"
    assert_true "[ ! -s '$sb/send-keys.log' ]" \
        "no keystroke is sent to a golem that is legitimately planning"
}

# The #659 case: plan mode WITH commits beyond base. Commits mean past planning by
# definition, so this is unambiguous drift.
test_mode_drift_detected_via_commits() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once
    assert_exit 1 "$RUN_RC" "drift exits 1"
    assert_contains "$RUN_OUT" "DRIFT" "plan mode with commits beyond base is drift"
}

# The state-file arm standing ALONE: phase says implement, zero commits (a golem
# that has started implementing but not yet committed). Proves the primary signal
# works independently of the commit-count corroboration.
test_mode_drift_detected_via_state_file() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 0 implement
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once
    assert_exit 1 "$RUN_RC" "drift via the state-file phase exits 1"
    assert_contains "$RUN_OUT" "DRIFT" "phase=implement in plan mode is drift with no commits"
}

# The commit arm standing ALONE, with NO state file at all — the case Josh's issue
# comment calls out: a Mode-2 worktree dispatch may never write one, so the check
# cannot depend on it.
test_mode_drift_detected_without_state_file() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 3
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once
    assert_exit 1 "$RUN_RC" "drift is detected with no state file present"
    assert_contains "$RUN_OUT" "DRIFT" "the commit-count arm stands alone"
}

# A HEALTHY implementing golem in auto mode is not a violation. This guards the
# resolver-authority decision: issue #659's invariant table proposed acceptEdits
# for L1-L3, but the resolver and golem-launch.sh both say auto for L2-L4, so a
# check built from the issue's table verbatim would flag every healthy L3 golem.
test_mode_auto_while_implementing_is_not_drift() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2 implement
    _pane_footer "$(_footer_auto)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once
    assert_exit 0 "$RUN_RC" "an implementing golem in auto mode is healthy (exit 0)"
    assert_not_contains "$RUN_OUT" "DRIFT" "auto mode past planning is not drift"
}

# --- auto-correct -----------------------------------------------------------

# The keystroke LANDS: send → re-scrape → confirmed, reported once.
test_mode_fix_corrects_and_confirms() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    command : >"$sb/flip"
    plant_mode_tmux "$sb" "$sb/pane.txt" "$sb/flip"
    run_mode_check "$sb" --once --fix
    assert_exit 0 "$RUN_RC" "a corrected golem exits 0"
    assert_contains "$RUN_OUT" "auto-corrected" "the correction is reported LOUDLY, not silently"
    assert_true "[ -s '$sb/send-keys.log' ]" "a keystroke was actually sent"
}

# The keystroke does NOT stick (no flip file → send-keys changes nothing). The
# check must BOUND its attempts and escalate rather than loop forever. This whole
# bug class is "the keystroke did not do what was assumed", so a fire-and-forget
# implementation would hang here instead of failing.
test_mode_fix_bounded_then_escalates() {
    local sb attempts
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" --once --fix
    assert_exit 1 "$RUN_RC" "an uncorrectable golem exits 1"
    assert_contains "$RUN_OUT" "ESCALATION" "a mode that will not stick escalates to the operator"
    attempts="$(command wc -l <"$sb/send-keys.log" | command tr -d ' ')"
    assert_true "[ '$attempts' -eq 3 ]" \
        "attempts are bounded at GOLEM_MODE_FIX_ATTEMPTS=3, not unbounded (sent $attempts)"
}

# The attempt bound is configurable, and the bound is what is honored — not a
# hardcoded 3 that merely happens to match the default.
test_mode_fix_attempts_env_override() {
    local sb attempts
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            -uBASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=main GOLEM_MODE_FIX_ATTEMPTS=1 \
            "$REAL_BASH" "$MODE_CHECK" --once --fix 2>&1)" || RUN_RC=$?
    attempts="$(command wc -l <"$sb/send-keys.log" | command tr -d ' ')"
    assert_true "[ '$attempts' -eq 1 ]" \
        "GOLEM_MODE_FIX_ATTEMPTS=1 sends exactly one keystroke (sent $attempts)"
}

# The auto-correct must send tmux's BACK-TAB key name, not the `S-Tab` modifier
# form. Measured on tmux 3.5a: `send-keys S-Tab` delivers `^I` — a PLAIN TAB with
# the Shift modifier silently dropped — while `send-keys BTab` delivers `^[[Z`,
# the real CSI Z shift-tab. Both return rc=0, so the send's own exit status
# cannot tell them apart; only asserting on the key ARGUMENT can. With `S-Tab`
# the golem gets a bare Tab in its prompt, the mode never cycles, and the loop
# burns every attempt before escalating a golem it could have fixed.
test_mode_fix_sends_backtab_not_s_tab() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    command : >"$sb/flip"
    plant_mode_tmux "$sb" "$sb/pane.txt" "$sb/flip"
    run_mode_check "$sb" --once --fix
    assert_contains "$(command cat "$sb/send-keys.log")" "BTab" \
        "the mode-cycle keystroke is tmux's BTab (real shift-tab)"
    assert_not_contains "$(command cat "$sb/send-keys.log")" "S-Tab" \
        "never S-Tab, which tmux downgrades to a plain Tab"
}

# An `unknown` pane read after the send is NOT a confirmed correction. `unknown`
# is the documented "cannot tell" state (a pane that has not repainted, a modal
# raised by the keystroke itself); accepting it would report a fix that was never
# verified — the exact assume-the-keystroke-worked failure this check exists to
# close, and a contradiction of pane_mode_class's own contract. It must consume a
# retry and ultimately escalate instead.
test_mode_fix_unknown_pane_is_not_a_confirmed_fix() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    command : >"$sb/flip"
    # The "keystroke lands" path rewrites the pane to a FOOTERLESS body, which
    # classifies as `unknown` — not plan, but not a confirmed working mode.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    ls) printf 'golem-7: 1 windows\n' ;;
    capture-pane) command cat "$sb/pane.txt" ;;
    send-keys)
        printf '%s\n' "\$*" >>"$sb/send-keys.log"
        printf 'some output\nno mode footer at all\n' >"$sb/pane.txt"
        ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    run_mode_check "$sb" --once --fix
    assert_exit 1 "$RUN_RC" "an unconfirmable correction exits 1, not 0"
    assert_contains "$RUN_OUT" "ESCALATION" "an unknown pane escalates rather than claiming success"
    assert_not_contains "$RUN_OUT" "auto-corrected" "an unverified mode is never reported as corrected"
}

# --- multi-golem aggregation ------------------------------------------------

# STICKY-WORST EXIT CODE. golem-7 cannot be fixed (escalates); golem-8, processed
# after it, fixes cleanly. The run must still exit non-zero — a later golem's
# success must not overwrite an earlier golem's unresolved escalation, or a sweep
# that PRINTED an escalation would report "all handled" to its caller and the
# waiting golem would go unnoticed. Every other test here drives a single-session
# stub, where any aggregation is trivially correct; this is the only shape that
# can see the bug.
test_mode_multi_golem_escalation_is_sticky() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2
    _mode_worktree "$sb" 8 2
    _pane_footer "$(_footer_plan)" >"$sb/paneA.txt"
    _pane_footer "$(_footer_plan)" >"$sb/paneB.txt"
    command : >"$sb/flipB"
    plant_mode_tmux2 "$sb" "$sb/paneA.txt" "$sb/paneB.txt" "$sb/flipB"
    run_mode_check "$sb" --once --fix
    assert_contains "$RUN_OUT" "ESCALATION" "the unfixable golem escalates"
    assert_contains "$RUN_OUT" "auto-corrected" "the fixable golem is still corrected"
    assert_exit 1 "$RUN_RC" \
        "a later golem's clean fix does NOT clear the earlier escalation (sticky-worst)"
}

# Both golems healthy across a multi-session sweep → exit 0. Guards the sticky
# latch against the opposite error: a latch that never clears would report
# failure on a clean fleet, making the exit code useless in the other direction.
test_mode_multi_golem_all_healthy_exits_zero() {
    local sb
    new_sandbox sb
    _mode_worktree "$sb" 7 2 implement
    _mode_worktree "$sb" 8 2 implement
    _pane_footer "$(_footer_auto)" >"$sb/paneA.txt"
    _pane_footer "$(_footer_auto)" >"$sb/paneB.txt"
    plant_mode_tmux2 "$sb" "$sb/paneA.txt" "$sb/paneB.txt"
    run_mode_check "$sb" --once
    assert_exit 0 "$RUN_RC" "a fleet with no drift exits 0"
    assert_not_contains "$RUN_OUT" "DRIFT" "no drift is reported for healthy golems"
}

# --- verify-send (the #659 rider) -------------------------------------------

# A send that changes the pane is CONFIRMED.
test_mode_verify_send_confirms_delivery() {
    local sb
    new_sandbox sb
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    command : >"$sb/flip"
    plant_mode_tmux "$sb" "$sb/pane.txt" "$sb/flip"
    run_mode_check "$sb" verify-send 7 1 Enter
    assert_exit 0 "$RUN_RC" "a delivered send exits 0"
    assert_contains "$RUN_OUT" "confirmed" "delivery is confirmed by re-scrape"
}

# A send SWALLOWED by an open modal leaves the pane unchanged. tmux still reports
# success — it delivered to the pane, the application discarded it — so exit
# status alone proves nothing. This is the rider: two such sends vanished during
# the reported session and were only found by grepping the transcript.
test_mode_verify_send_detects_swallowed() {
    local sb
    new_sandbox sb
    _pane_footer "$(_footer_plan)" >"$sb/pane.txt"
    plant_mode_tmux "$sb" "$sb/pane.txt"
    run_mode_check "$sb" verify-send 7 1 Enter
    assert_exit 1 "$RUN_RC" "a swallowed send exits non-zero"
    assert_contains "$RUN_OUT" "NOT CONFIRMED" "a swallowed send is reported, not assumed delivered"
}

# --- verify-text: the free-text directive relay (#974) ----------------------

# _pane_composer <text> — a pane whose COMPOSER line carries <text> (empty for a
# submitted/idle prompt), plus the auto-mode footer.
#
# THE GLYPH AND THE NBSP ARE REAL BYTES, and both are load-bearing — same rule as
# the mode footers above, one level deeper. The borrowed classifier
# (pane_prompt_line_class) anchors on the prompt glyph + NBSP *pair*, so a
# fixture writing either as an escape sequence, or padding with a plain space,
# would classify `unknown` and the test would pass with OR without the fix.
# ❯ = e29daf, NBSP = c2a0.
_pane_composer() {
    command printf 'work output\n\n\342\235\257\302\240%s\n  %s\n' "$1" "$(_footer_auto)"
}

# plant_text_tmux <sandbox> <pane-file> <submits-needed> — a tmux stub that
# models the MEASURED #974 behavior rather than an idealized one.
#
#   * a `-l` (literal) send writes the payload into the composer line
#   * a bare `Enter` counts as a submit attempt, and clears the composer only
#     once <submits-needed> of them have arrived
#
# <submits-needed>=2 is the reported bug: the first Enter does not take. =1 is a
# healthy golem. A large value models a genuinely stuck composer. Every send is
# appended to send-keys.log as "$*", so a test can assert the payload and the
# submit went out as SEPARATE invocations — the property that actually fixes
# this, and the one a single combined call would silently lose.
plant_text_tmux() {
    local sb="$1" panefile="$2" needed="$3"
    command mkdir -p "$sb/bin"
    command printf '0\n' >"$sb/submits"
    command cat >"$sb/bin/tmux" <<EOF
#!/usr/bin/env bash
# Test stub: a composer that needs <needed> Enters before it submits.
case "\$1" in
    ls) printf 'golem-7: 1 windows\n' ;;
    capture-pane) command cat "$panefile" ;;
    send-keys)
        printf '%s\n' "\$*" >>"$sb/send-keys.log"
        case "\$*" in
            *-l*)
                # The payload is typed into the composer — visible, unsubmitted.
                printf 'work output\n\n\342\235\257\302\240typed directive\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$panefile"
                ;;
            *Enter*)
                n=\$(( \$(command cat "$sb/submits") + 1 ))
                printf '%s\n' "\$n" >"$sb/submits"
                if [ "\$n" -ge "$needed" ]; then
                    printf 'work output\n\n\342\235\257\302\240\n  \342\217\265\342\217\265 auto mode on (shift+tab to cycle)\n' >"$panefile"
                fi
                ;;
        esac
        ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# THE REPORTED BUG (#974): the first Enter does not submit. The relay must notice
# and send another, rather than returning "delivered" on a directive still
# sitting in the composer.
test_mode_verify_text_retries_second_enter() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 2
    run_mode_check "$sb" verify-text 7 "OPERATOR DIRECTIVE: ship it"
    assert_exit 0 "$RUN_RC" "a directive needing a second Enter still succeeds"
    assert_contains "$RUN_OUT" "composer empty" "success is reported as the composer emptying"
    assert_equals 2 "$(command grep -c 'Enter' "$sb/send-keys.log")" \
        "the relay sent a SECOND Enter after the first did not submit"
}

# THE FIX ITSELF: payload and submit must go out as SEPARATE send-keys calls.
# Combined, the trailing CR arrives in the same read() as the payload and the
# composer treats it as a newline within the message — which is the whole bug. A
# test asserting only the exit code would pass on the combined form too, so this
# is the case that makes send-and-hope impossible to reintroduce.
test_mode_verify_text_splits_payload_from_submit() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text 7 "OPERATOR DIRECTIVE: ship it"
    assert_exit 0 "$RUN_RC" "a directive that submits first time succeeds"
    local payload_line
    payload_line="$(command grep -- '-l' "$sb/send-keys.log")"
    assert_contains "$payload_line" "OPERATOR DIRECTIVE" "the payload went out literally (-l)"
    assert_not_contains "$payload_line" "Enter" \
        "the payload send carries NO Enter — combined, the CR is read as a newline, not a submit"
}

# A composer that never empties must FAIL LOUD after the bound, not spin and not
# report delivery. The operator guidance matters as much as the exit code: the
# text is sitting unsent, so re-sending the payload would double it.
test_mode_verify_text_unsubmitted_fails_loud() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 99
    run_mode_check "$sb" verify-text 7 "OPERATOR DIRECTIVE: ship it"
    assert_exit 1 "$RUN_RC" "a directive that never submits exits non-zero"
    assert_contains "$RUN_OUT" "NOT SUBMITTED" "the stall is reported, not assumed delivered"
    assert_not_contains "$RUN_OUT" "composer empty" "it must NOT claim the composer emptied"
}

# THE CONTROL, and the reason verify-text exists as a separate subcommand.
# verify-send's predicate asks only whether the pane CHANGED — and typed-but-
# unsubmitted text changes it, because the characters appear in the composer. So
# the old guard reports "confirmed" on exactly the #974 failure. This test pins
# that blindness deliberately: it fails if someone later collapses the two
# subcommands, which would quietly restore the false confirm.
test_mode_verify_send_blind_to_unsubmitted_text() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 99
    run_mode_check "$sb" verify-send 7 -l "OPERATOR DIRECTIVE: ship it"
    assert_exit 0 "$RUN_RC" "verify-send confirms a merely-changed pane (why verify-text exists)"
    assert_contains "$RUN_OUT" "confirmed" "the pane-changed predicate cannot see an unsubmitted directive"
}

# A directive beginning with a dash must reach the golem as TEXT, not be eaten as
# a tmux flag — which is what `-l --` buys. Operator directives realistically
# start with one ("--force ...", "-- revert that").
test_mode_verify_text_dash_payload_is_literal() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text 7 "--force: revert the last commit"
    assert_exit 0 "$RUN_RC" "a dash-leading directive is delivered, not parsed as a flag"
    assert_contains "$(command cat "$sb/send-keys.log")" "--force: revert the last commit" \
        "the dash-leading payload reached tmux intact"
}

# Typing APPENDS. Relaying onto a composer that already holds text would submit
# one MERGED directive — a decision the operator never wrote, delivered
# confidently. That is worse than the bug being fixed, where the text at least
# sat visible and unsent. So the relay refuses, and must leave the queued text
# untouched: what is already there is someone's input, not ours to discard.
test_mode_verify_text_refuses_occupied_composer() {
    local sb
    new_sandbox sb
    _pane_composer "half-typed operator text" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text 7 "SECOND DIRECTIVE"
    assert_exit 1 "$RUN_RC" "relaying onto an occupied composer is refused"
    assert_contains "$RUN_OUT" "NOT SENT" "the refusal says nothing was sent, not that delivery failed"
    assert_equals "half-typed operator text" \
        "$(command sed -n '3p' "$sb/pane.txt" | command tr -d '\342\235\257\302\240')" \
        "the queued text is left untouched — not appended to, not submitted"
    # No log at all is the STRONGEST form of this assertion (not one send was
    # made), so read it through a default rather than guarding on the file's
    # existence — a trailing `[ -f ] && ...` would return the test body's status
    # as non-zero precisely when the guard held.
    assert_not_contains "$(command cat "$sb/send-keys.log" 2>/dev/null || true)" \
        "SECOND DIRECTIVE" "the payload never reached tmux"
}

# Arity is exact: the directive is ONE quoted argument. An unquoted multi-word
# directive would otherwise arrive as N arguments and silently relay only the
# first word — a wrong directive delivered confidently.
test_mode_verify_text_requires_single_text_arg() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text 7 OPERATOR DIRECTIVE ship it
    assert_exit 2 "$RUN_RC" "an unquoted multi-word directive is refused, not truncated"
    assert_contains "$RUN_OUT" "ONE argument" "the message says to quote the whole directive"
}

# An EMPTY directive is its own guard, distinct from the arity check above: the
# arg count is right, the content is not. Relaying it would submit a blank turn
# to the golem — a no-op that still consumes the operator's brokered decision.
test_mode_verify_text_empty_directive_exits_2() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text 7 ""
    assert_exit 2 "$RUN_RC" "an empty directive is refused"
    assert_contains "$RUN_OUT" "non-empty" "the message names the empty payload"
    assert_not_contains "$(command cat "$sb/send-keys.log" 2>/dev/null || true)" "send-keys" \
        "nothing was sent for an empty directive"
}

# The golem-id validation is now SHARED by both subcommands (resolve_golem_session),
# so a loosened character class would silently affect both. It guards a real
# hazard: the id becomes a `tmux -t` target, so it must not carry metacharacters.
test_mode_verify_text_invalid_id_exits_2() {
    local sb
    new_sandbox sb
    _pane_composer "" >"$sb/pane.txt"
    plant_text_tmux "$sb" "$sb/pane.txt" 1
    run_mode_check "$sb" verify-text "7/../evil" "OPERATOR DIRECTIVE: ship it"
    assert_exit 2 "$RUN_RC" "a malformed golem id is refused"
    assert_contains "$RUN_OUT" "invalid golem id" "the refusal names the bad id"
    assert_not_contains "$(command cat "$sb/send-keys.log" 2>/dev/null || true)" "OPERATOR DIRECTIVE" \
        "no payload is sent to an unvalidated target"
}

# --- fail-loud + usage ------------------------------------------------------

# Absent tmux must FAIL LOUD, never report a clean "no drift". A check that says
# healthy because it could not look is indistinguishable from a working check —
# the #538/#571 skip-sentinel lesson.
test_mode_missing_tmux_fails_loud() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/emptybin"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            -uBASH_ENV \
            HOME="$sb" PATH="$sb/emptybin" \
            "$REAL_BASH" "$MODE_CHECK" --once 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "missing tmux exits 2, not 0"
    assert_contains "$RUN_OUT" "tmux not found" "the failure names the missing tool"
    assert_not_contains "$RUN_OUT" "No live golem" "it must NOT report a clean scan it could not perform"
}

test_mode_unknown_arg_exits_2() {
    local sb
    new_sandbox sb
    plant_mode_tmux "$sb" "$sb/pane.txt"
    command : >"$sb/pane.txt"
    run_mode_check "$sb" --bogus
    assert_exit 2 "$RUN_RC" "an unknown argument exits 2"
}

test_mode_bad_interval_exits_2() {
    local sb
    new_sandbox sb
    plant_mode_tmux "$sb" "$sb/pane.txt"
    command : >"$sb/pane.txt"
    run_mode_check "$sb" --watch --interval 0
    assert_exit 2 "$RUN_RC" "a non-positive --interval exits 2"
}
