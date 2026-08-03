#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/ci-wait-timeout.sh (issue #588).
#
# The script owns the stop DECISION for the ship-issue CI-wait poll loop — the
# mechanized replacement for prose the shipping model used to interpret by hand.
# Before #588, LIBRARIAN_CI_WAIT_TIMEOUT / LIBRARIAN_CI_WAIT_MAX_EXTENSIONS were
# documented in six files, with defaults, and read by NO code: the bound was
# whatever the model happened to do. A silent regression here (a wrong ceiling, an
# extension that never increments, a threshold that stops reading the env
# override, a fail-loud exit the caller's degradation path keys on) would return
# the loop to that state, so this gate pins the deterministic decision table.
#
# This suite and tests/validate-workflow-wall-timeout.sh cover the two wrappers
# over the SHARED threshold-check.sh. That overlap is deliberate, not redundant:
# each wrapper's whole contribution is its var names and defaults (15/2 -> ceiling
# 45 here, 20/1 -> ceiling 40 there), so a swap or a typo in either wrapper is
# invisible to the other's suite. The boundary values asserted below are
# therefore this file's real subject; the shared arithmetic is what makes them
# cheap to assert.
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CIW="$REPO_ROOT/plugins/workflow/scripts/ci-wait-timeout.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "ci-wait-timeout.sh (#588)"

# val <key> <output> — echo the value of a `key=value` line from the script's
# stdout. Keeps assertions terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# --- Documented defaults ------------------------------------------------------
# The 15/2 -> 45 contract is what ship-protocol.md, ci-review-protocol.md and
# plugins/workflow/README.md all state to operators. Asserting the ceiling
# explicitly (rather than only the verdicts it produces) is what makes a wrapper
# that silently inherited the wall-timeout's 20/1 a failure here.

test_default_ceiling_is_45() {
    local out
    out="$("$CIW" check --elapsed-min 0 --level 3)"
    assert_equals "45" "$(val ceiling_min "$out")" \
        "Default ceiling is 15 * (2 + 1) = 45 min, as every doc site states"
    assert_equals "15" "$(val next_deadline_min "$out")" \
        "The first checkpoint is at the 15-min default timeout"
}

# --- Decision table (defaults: TIMEOUT=15, MAX_EXTENSIONS=2 -> ceiling 45) -----

test_continue_below_checkpoint() {
    local out
    out="$("$CIW" check --elapsed-min 14 --level 3)"
    assert_equals "continue" "$(val verdict "$out")" "14 min is below the 15-min checkpoint"
    assert_equals "0" "$(val extensions_used "$out")" "continue does not consume an extension"
}

test_continue_defaults_extensions_used_to_zero() {
    # Omitting --extensions-used must behave exactly as passing 0.
    local with without
    without="$("$CIW" check --elapsed-min 10 --level 3)"
    with="$("$CIW" check --elapsed-min 10 --level 3 --extensions-used 0)"
    assert_equals "$with" "$without" "--extensions-used defaults to 0"
}

test_l3_auto_extends_at_checkpoint() {
    local out
    out="$("$CIW" check --elapsed-min 15 --level 3)"
    assert_equals "extend" "$(val verdict "$out")" "L3 auto-extends at the exact checkpoint"
    assert_equals "1" "$(val extensions_used "$out")" "the granted extension is counted"
    assert_equals "30" "$(val next_deadline_min "$out")" "the next deadline is one more 15-min interval"
}

test_l4_auto_extends_at_checkpoint() {
    local out
    out="$("$CIW" check --elapsed-min 20 --level 4)"
    assert_equals "extend" "$(val verdict "$out")" "L4 auto-extends past the checkpoint"
    assert_equals "1" "$(val extensions_used "$out")" "the granted extension is counted"
}

test_second_extension_is_granted() {
    # MAX_EXTENSIONS=2 means TWO auto-grants before the ceiling — one more than
    # the wall-timeout's budget. A wrapper that inherited MAX_EXTENSIONS=1 would
    # return `stop` here, so this is the case that distinguishes the two.
    local out
    out="$("$CIW" check --elapsed-min 30 --level 4 --extensions-used 1)"
    assert_equals "extend" "$(val verdict "$out")" "a second extension is granted (MAX_EXTENSIONS=2)"
    assert_equals "2" "$(val extensions_used "$out")" "the second extension is counted"
    assert_equals "45" "$(val next_deadline_min "$out")" "the final window runs to the 45-min ceiling"
}

test_l1_l2_checkpoint_never_auto_extends() {
    local out1 out2
    out1="$("$CIW" check --elapsed-min 15 --level 1)"
    out2="$("$CIW" check --elapsed-min 15 --level 2)"
    assert_equals "checkpoint" "$(val verdict "$out1")" "L1 asks the human, never auto-extends"
    assert_equals "checkpoint" "$(val verdict "$out2")" "L2 asks the human, never auto-extends"
    assert_equals "0" "$(val extensions_used "$out1")" \
        "a checkpoint verdict does NOT consume an extension (the human has not chosen yet)"
}

test_stop_when_extensions_exhausted() {
    local out
    out="$("$CIW" check --elapsed-min 45 --level 4 --extensions-used 2)"
    assert_equals "stop" "$(val verdict "$out")" "both extensions spent at the ceiling -> stop"
    assert_equals "45" "$(val ceiling_min "$out")" "the ceiling is reported with the stop"
}

test_stop_is_level_independent() {
    # The ceiling STOP is the same at every level — L1-L2 do not get an
    # interactive reprieve past the hard cap.
    local lvl out
    for lvl in 1 2 3 4; do
        out="$("$CIW" check --elapsed-min 45 --level "$lvl" --extensions-used 2)"
        assert_equals "stop" "$(val verdict "$out")" "L$lvl stops at the ceiling"
    done
}

test_stop_at_exact_ceiling() {
    local out
    out="$("$CIW" check --elapsed-min 45 --level 3 --extensions-used 1)"
    assert_equals "stop" "$(val verdict "$out")" "elapsed == ceiling stops, even with an extension left"
}

test_stop_when_already_past_ceiling() {
    local out
    out="$("$CIW" check --elapsed-min 90 --level 4 --extensions-used 0)"
    assert_equals "stop" "$(val verdict "$out")" \
        "elapsed far past the ceiling stops immediately, never extends back under it"
}

# --- Env overrides move the boundaries ----------------------------------------
# These are the assertions that make the variables REAL: an operator setting
# LIBRARIAN_CI_WAIT_TIMEOUT=5 gets a 5-min checkpoint, provably. That guarantee
# is exactly what #588 found missing.

test_timeout_override_moves_checkpoint() {
    local out
    out="$(LIBRARIAN_CI_WAIT_TIMEOUT=5 "$CIW" check --elapsed-min 5 --level 3)"
    assert_equals "extend" "$(val verdict "$out")" "TIMEOUT=5 puts the checkpoint at 5 min"
    assert_equals "15" "$(val ceiling_min "$out")" "TIMEOUT=5 with 2 extensions gives a 15-min ceiling"
    # And the same elapsed is still `continue` under the default — proving the
    # override, not the elapsed value, is what moved the boundary.
    local baseline
    baseline="$("$CIW" check --elapsed-min 5 --level 3)"
    assert_equals "continue" "$(val verdict "$baseline")" \
        "the same 5 min is still continue at the default 15-min timeout (the override did the work)"
}

test_max_extensions_override_raises_ceiling() {
    local out
    out="$(LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=5 "$CIW" check --elapsed-min 45 --level 3 --extensions-used 2)"
    assert_equals "extend" "$(val verdict "$out")" "a raised MAX_EXTENSIONS keeps extending past the default ceiling"
    assert_equals "90" "$(val ceiling_min "$out")" "MAX_EXTENSIONS=5 gives a 15 * 6 = 90 min ceiling"
}

test_zero_extensions_stops_at_first_checkpoint() {
    local out
    out="$(LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=0 "$CIW" check --elapsed-min 15 --level 4)"
    assert_equals "stop" "$(val verdict "$out")" \
        "MAX_EXTENSIONS=0 makes the first checkpoint the ceiling, even at L4"
    assert_equals "15" "$(val ceiling_min "$out")" "the ceiling collapses to one interval"
}

# --- Fail-loud exits (exit 2 + message on stderr) -----------------------------

test_missing_elapsed_fails_loud() {
    local rc=0 err
    err="$("$CIW" check --level 3 2>&1 >/dev/null || true)"
    "$CIW" check --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --elapsed-min exits 2"
    assert_contains "$err" "needs --elapsed-min" "missing --elapsed-min fails loud on stderr"
    assert_contains "$err" "ci-wait-timeout" \
        "the message names THIS tool, not the shared library or its sibling"
}

test_noninteger_elapsed_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min notanumber --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "non-integer --elapsed-min exits 2"
}

test_negative_elapsed_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min -5 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --elapsed-min exits 2 (leading - is not a non-negative int)"
}

test_missing_level_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min 10 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --level exits 2"
}

test_bad_level_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min 10 --level 9 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--level out of 1-4 exits 2"
}

test_negative_extensions_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min 10 --level 3 --extensions-used -1 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --extensions-used exits 2"
}

test_bad_timeout_env_fails_loud() {
    local rc=0 err
    err="$(LIBRARIAN_CI_WAIT_TIMEOUT=0 "$CIW" check --elapsed-min 10 --level 3 2>&1 >/dev/null || true)"
    LIBRARIAN_CI_WAIT_TIMEOUT=0 "$CIW" check --elapsed-min 10 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "TIMEOUT < 1 exits 2 (a bad override never silently picks a wrong ceiling)"
    assert_contains "$err" "LIBRARIAN_CI_WAIT_TIMEOUT" \
        "the message names the CI-wait var the operator actually set"
}

test_bad_max_extensions_env_fails_loud() {
    local rc=0 err
    err="$(LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=x "$CIW" check --elapsed-min 10 --level 3 2>&1 >/dev/null || true)"
    LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=x "$CIW" check --elapsed-min 10 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "non-integer MAX_EXTENSIONS exits 2"
    assert_contains "$err" "LIBRARIAN_CI_WAIT_MAX_EXTENSIONS" \
        "the message names the CI-wait extensions var"
}

test_wall_vars_do_not_leak_in() {
    # The sibling loop's vars must have NO effect here. Without per-wrapper var
    # names, one loop's override would silently retune the other — and the
    # symptom (a 40-min CI ceiling) would look like a plausible default.
    local out
    out="$(LIBRARIAN_WORKFLOW_WALL_TIMEOUT=99 LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS=9 \
        "$CIW" check --elapsed-min 0 --level 3)"
    assert_equals "45" "$(val ceiling_min "$out")" \
        "the wall-timeout's env vars do not affect the CI-wait ceiling"
}

test_unknown_subcommand_fails_loud() {
    local rc=0
    "$CIW" bogus >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "unknown subcommand exits 2"
}

test_no_subcommand_fails_loud() {
    local rc=0
    "$CIW" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "no subcommand exits 2"
}

# --- Leading-zero / octal rejection -------------------------------------------
# A digit string with a leading zero (030, 08, 010) feeds bash arithmetic as
# OCTAL: it either applies a silently-wrong threshold or crashes past the exit-2
# contract. Every numeric parameter must reject it, across all four inputs.

test_leading_zero_elapsed_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min 030 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --elapsed-min (030) exits 2, not an octal verdict"
}

test_leading_zero_elapsed_with_8_or_9_fails_loud() {
    # 08/09 are the crash variant ("value too great for base") — must be exit 2,
    # not the raw bash arithmetic error (exit 1) that bypasses the die path.
    local rc=0
    "$CIW" check --elapsed-min 09 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --elapsed-min with a 9 digit exits 2, does not crash"
}

test_leading_zero_extensions_fails_loud() {
    local rc=0
    "$CIW" check --elapsed-min 10 --level 3 --extensions-used 008 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --extensions-used (008) exits 2, does not crash"
}

test_leading_zero_timeout_env_fails_loud() {
    local rc=0
    LIBRARIAN_CI_WAIT_TIMEOUT=030 "$CIW" check --elapsed-min 6 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero TIMEOUT (030) exits 2, not a silent octal ceiling"
}

test_leading_zero_max_extensions_env_fails_loud() {
    local rc=0
    LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=010 "$CIW" check --elapsed-min 6 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero MAX_EXTENSIONS (010) exits 2"
}

test_plain_zero_still_valid() {
    # `0` is the sole legitimate zero — the leading-zero rejection must not eat it.
    local out
    out="$("$CIW" check --elapsed-min 0 --level 3 --extensions-used 0)"
    assert_equals "continue" "$(val verdict "$out")" "elapsed 0 is a valid non-negative integer"
}

test_extensions_over_max_fails_loud() {
    # K > MAX_EXTENSIONS is invalid caller state; unchecked it inflates
    # next_deadline past the ceiling and returns `continue` forever.
    local rc=0 err
    err="$("$CIW" check --elapsed-min 50 --level 1 --extensions-used 5 2>&1 >/dev/null || true)"
    "$CIW" check --elapsed-min 50 --level 1 --extensions-used 5 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--extensions-used past MAX_EXTENSIONS exits 2"
    assert_contains "$err" "exceeds" "the over-ceiling extensions message names the invariant"
}

test_extensions_equal_max_is_valid() {
    # K == MAX_EXTENSIONS is the boundary and legitimate (the last granted window).
    local out
    out="$("$CIW" check --elapsed-min 40 --level 3 --extensions-used 2)"
    assert_equals "continue" "$(val verdict "$out")" \
        "K == MAX_EXTENSIONS is valid (still inside the final window)"
}

# --- Integration: a bounded poll loop terminates on stuck CI -------------------
# `gh pr checks` lives in the model runtime and cannot be driven from a sandboxed
# bash test, so a true "the poll loop exits" fixture is not buildable here. What
# IS testable — and is the mechanized core of the fix — is that a caller that
# consults the helper each poll ALWAYS reaches `stop` in bounded time for CI that
# never completes. Before #588 nothing guaranteed this: the model tracked the
# budget by hand, and a golem could poll a stuck run indefinitely.
test_bounded_loop_reaches_stop_on_stuck_ci() {
    local elapsed=0 ext=0 verdict="" out iterations=0
    # Poll in 5-min steps up to a hard 200-min safety bound (well over 4x the
    # default ceiling) — if the oracle ever failed to say `stop`, this bound
    # catches the runaway instead of hanging the test.
    while [ "$iterations" -lt 40 ]; do
        iterations=$((iterations + 1))
        out="$("$CIW" check --elapsed-min "$elapsed" --level 4 --extensions-used "$ext")"
        verdict="$(val verdict "$out")"
        case "$verdict" in
            stop) break ;;
            extend) ext="$(val extensions_used "$out")" ;;
            continue | checkpoint) : ;;
        esac
        elapsed=$((elapsed + 5))
    done
    assert_equals "stop" "$verdict" "a never-completing L4 CI run is driven to stop by the per-poll oracle"
    # Default ceiling is 45 min; at a 5-min cadence the loop must stop by ~10
    # polls, far under the safety bound — proving termination comes from the
    # oracle, not from the iteration cap.
    assert_true "[ $elapsed -le 50 ]" "stop is reached at the ~45-min ceiling, not the 200-min safety bound"
}

run_test test_default_ceiling_is_45 "the documented 15/2 defaults give a 45-min ceiling"
run_test test_continue_below_checkpoint "continue below the checkpoint"
run_test test_continue_defaults_extensions_used_to_zero "--extensions-used defaults to 0"
run_test test_l3_auto_extends_at_checkpoint "L3 auto-extends at the checkpoint"
run_test test_l4_auto_extends_at_checkpoint "L4 auto-extends past the checkpoint"
run_test test_second_extension_is_granted "a second extension is granted (MAX_EXTENSIONS=2)"
run_test test_l1_l2_checkpoint_never_auto_extends "L1-L2 checkpoint, never auto-extend"
run_test test_stop_when_extensions_exhausted "stop when extensions exhausted"
run_test test_stop_is_level_independent "the ceiling stop fires at every level"
run_test test_stop_at_exact_ceiling "stop at the exact ceiling"
run_test test_stop_when_already_past_ceiling "stop past the ceiling, never extend back under it"
run_test test_timeout_override_moves_checkpoint "TIMEOUT override moves the checkpoint"
run_test test_max_extensions_override_raises_ceiling "MAX_EXTENSIONS override raises the ceiling"
run_test test_zero_extensions_stops_at_first_checkpoint "MAX_EXTENSIONS=0 stops at the first checkpoint"
run_test test_missing_elapsed_fails_loud "missing --elapsed-min -> exit 2"
run_test test_noninteger_elapsed_fails_loud "non-integer --elapsed-min -> exit 2"
run_test test_negative_elapsed_fails_loud "negative --elapsed-min -> exit 2"
run_test test_missing_level_fails_loud "missing --level -> exit 2"
run_test test_bad_level_fails_loud "bad --level -> exit 2"
run_test test_negative_extensions_fails_loud "negative --extensions-used -> exit 2"
run_test test_bad_timeout_env_fails_loud "bad TIMEOUT env -> exit 2, naming the var"
run_test test_bad_max_extensions_env_fails_loud "bad MAX_EXTENSIONS env -> exit 2, naming the var"
run_test test_wall_vars_do_not_leak_in "the sibling loop's env vars do not retune this one"
run_test test_unknown_subcommand_fails_loud "unknown subcommand -> exit 2"
run_test test_no_subcommand_fails_loud "no subcommand -> exit 2"
run_test test_leading_zero_elapsed_fails_loud "leading-zero --elapsed-min -> exit 2 (octal guard)"
run_test test_leading_zero_elapsed_with_8_or_9_fails_loud "leading-zero --elapsed-min 09 -> exit 2, no crash"
run_test test_leading_zero_extensions_fails_loud "leading-zero --extensions-used -> exit 2, no crash"
run_test test_leading_zero_timeout_env_fails_loud "leading-zero TIMEOUT env -> exit 2 (no octal ceiling)"
run_test test_leading_zero_max_extensions_env_fails_loud "leading-zero MAX_EXTENSIONS env -> exit 2"
run_test test_plain_zero_still_valid "plain 0 is still a valid non-negative integer"
run_test test_extensions_over_max_fails_loud "--extensions-used past MAX_EXTENSIONS -> exit 2"
run_test test_extensions_equal_max_is_valid "--extensions-used == MAX_EXTENSIONS is valid"
run_test test_bounded_loop_reaches_stop_on_stuck_ci "bounded poll loop drives stuck CI to stop"

generate_report
