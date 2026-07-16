#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/workflow-wall-timeout.sh (issue #327).
#
# The script owns the wall-time stop DECISION for a bounded `Workflow` review
# invocation — the mechanized replacement for the #307 prose the ship-issue model
# used to interpret by hand (which let golem-266/252/263 wedge unbounded). A
# silent regression here (a wrong ceiling, an extension that never
# increments, a threshold that stops reading the env override, a fail-loud exit
# the caller's degradation path keys on) would re-open the exact cap-drift the
# issue was filed against, so this gate pins the deterministic decision table:
#   - continue below the current checkpoint,
#   - L3-L4 auto-extend vs L1-L2 human-checkpoint at the checkpoint,
#   - stop at the ceiling (extensions exhausted or already past the cap),
#   - env overrides move the boundaries,
#   - the fail-loud exit-2 paths (bad --elapsed-min / --level / --extensions-used,
#     bad env override, unknown subcommand).
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WALL="$REPO_ROOT/plugins/workflow/scripts/workflow-wall-timeout.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "workflow-wall-timeout.sh (#327)"

# val <key> <output> — echo the value of a `key=value` line from the script's
# stdout. Keeps assertions terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# --- Decision table (defaults: TIMEOUT=20, MAX_EXTENSIONS=1 -> ceiling 40) ----

test_continue_below_checkpoint() {
    local out
    out="$("$WALL" check --elapsed-min 10 --level 3)"
    assert_equals "continue" "$(val verdict "$out")" "10 min < 20 min checkpoint -> continue"
    assert_equals "40" "$(val ceiling_min "$out")" "ceiling = 20 * (1 + 1)"
    assert_equals "20" "$(val next_deadline_min "$out")" "next checkpoint is the first 20-min deadline"
    assert_equals "0" "$(val extensions_used "$out")" "no extension consumed while continuing"
}

test_continue_defaults_extensions_used_to_zero() {
    # Omitting --extensions-used must behave as 0 (fresh run, none granted yet).
    local with without
    with="$("$WALL" check --elapsed-min 5 --level 2 --extensions-used 0)"
    without="$("$WALL" check --elapsed-min 5 --level 2)"
    assert_equals "$with" "$without" "--extensions-used defaults to 0"
}

test_l3_auto_extends_at_checkpoint() {
    local out
    out="$("$WALL" check --elapsed-min 25 --level 3 --extensions-used 0)"
    assert_equals "extend" "$(val verdict "$out")" "L3 past first checkpoint with an extension left -> extend"
    assert_equals "1" "$(val extensions_used "$out")" "extend increments extensions_used to 1"
    assert_equals "40" "$(val next_deadline_min "$out")" "the granted interval pushes the deadline to 40"
}

test_l4_auto_extends_at_checkpoint() {
    local out
    out="$("$WALL" check --elapsed-min 20 --level 4 --extensions-used 0)"
    # elapsed == the checkpoint (20) is AT the boundary, not below it -> extend.
    assert_equals "extend" "$(val verdict "$out")" "L4 at the exact checkpoint boundary -> extend"
    assert_equals "1" "$(val extensions_used "$out")" "L4 extend increments extensions_used"
}

test_l1_l2_checkpoint_never_auto_extends() {
    local l1 l2
    l1="$("$WALL" check --elapsed-min 25 --level 1 --extensions-used 0)"
    l2="$("$WALL" check --elapsed-min 25 --level 2 --extensions-used 0)"
    assert_equals "checkpoint" "$(val verdict "$l1")" "L1 past the checkpoint -> human checkpoint, not auto-extend"
    assert_equals "checkpoint" "$(val verdict "$l2")" "L2 past the checkpoint -> human checkpoint, not auto-extend"
    assert_equals "0" "$(val extensions_used "$l1")" "a checkpoint verdict consumes no extension"
    # A checkpoint reports the current (un-extended) deadline, not the ceiling — a
    # regression that reused `ceiling` for next_deadline_min here would slip past
    # the other tests, which only assert it on continue/extend/stop.
    assert_equals "20" "$(val next_deadline_min "$l1")" "checkpoint reports the current deadline, not the ceiling"
    assert_equals "40" "$(val ceiling_min "$l1")" "checkpoint still reports the hard ceiling"
}

test_stop_when_extensions_exhausted() {
    # One extension already granted (K = MAX_EXTENSIONS = 1) and elapsed past the
    # extended deadline -> the ceiling; stop regardless of level.
    local l3 l4
    l3="$("$WALL" check --elapsed-min 45 --level 3 --extensions-used 1)"
    l4="$("$WALL" check --elapsed-min 45 --level 4 --extensions-used 1)"
    assert_equals "stop" "$(val verdict "$l3")" "L3 with extensions exhausted -> stop"
    assert_equals "stop" "$(val verdict "$l4")" "L4 with extensions exhausted -> stop (no level escapes the ceiling)"
    assert_equals "40" "$(val next_deadline_min "$l3")" "stop reports the ceiling as the deadline"
}

test_stop_at_exact_ceiling() {
    local out
    out="$("$WALL" check --elapsed-min 40 --level 4 --extensions-used 1)"
    assert_equals "stop" "$(val verdict "$out")" "elapsed == ceiling (40) -> stop"
}

test_stop_when_already_past_ceiling_even_with_extension_left() {
    # A single poll can jump straight past the hard cap (a long-blocking
    # TaskOutput). Even with an unused extension, elapsed >= ceiling must stop —
    # the cap is absolute, not "one more interval from wherever we are".
    local out
    out="$("$WALL" check --elapsed-min 50 --level 3 --extensions-used 0)"
    assert_equals "stop" "$(val verdict "$out")" "elapsed past the ceiling stops even with an extension unused"
}

# --- Env overrides move the boundaries --------------------------------------

test_timeout_override_moves_checkpoint() {
    local out
    out="$(LIBRARIAN_WORKFLOW_WALL_TIMEOUT=10 "$WALL" check --elapsed-min 12 --level 3 --extensions-used 0)"
    assert_equals "extend" "$(val verdict "$out")" "TIMEOUT=10 makes 12 past the first checkpoint"
    assert_equals "20" "$(val ceiling_min "$out")" "TIMEOUT=10, MAX_EXT=1 -> ceiling 20"
}

test_max_extensions_override_raises_ceiling() {
    local out
    out="$(LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS=3 "$WALL" check --elapsed-min 45 --level 3 --extensions-used 1)"
    # ceiling = 20 * (3 + 1) = 80; at 45 with 1 extension used, still below -> extend.
    assert_equals "80" "$(val ceiling_min "$out")" "MAX_EXTENSIONS=3 -> ceiling 80"
    assert_equals "extend" "$(val verdict "$out")" "raised ceiling turns a would-be stop into an extend"
    assert_equals "2" "$(val extensions_used "$out")" "extend grants the second of three extensions"
}

test_zero_extensions_stops_at_first_checkpoint() {
    local out
    out="$(LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS=0 "$WALL" check --elapsed-min 25 --level 4 --extensions-used 0)"
    assert_equals "stop" "$(val verdict "$out")" "MAX_EXTENSIONS=0 -> the first checkpoint IS the ceiling, even at L4"
    assert_equals "20" "$(val ceiling_min "$out")" "MAX_EXTENSIONS=0 -> ceiling == one timeout"
}

# --- Fail-loud exits (exit 2 + message on stderr) ---------------------------

test_missing_elapsed_fails_loud() {
    local rc=0 err
    err="$("$WALL" check --level 3 2>&1 >/dev/null || true)"
    "$WALL" check --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --elapsed-min exits 2"
    assert_contains "$err" "needs --elapsed-min" "missing --elapsed-min fails loud on stderr"
}

test_noninteger_elapsed_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min notanumber --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "non-integer --elapsed-min exits 2"
}

test_negative_elapsed_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min -5 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --elapsed-min exits 2 (leading - is not a non-negative int)"
}

test_missing_level_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min 10 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --level exits 2"
}

test_bad_level_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min 10 --level 9 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--level out of 1-4 exits 2"
}

test_negative_extensions_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min 10 --level 3 --extensions-used -1 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --extensions-used exits 2"
}

test_bad_timeout_env_fails_loud() {
    local rc=0
    LIBRARIAN_WORKFLOW_WALL_TIMEOUT=0 "$WALL" check --elapsed-min 10 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "TIMEOUT < 1 exits 2 (a bad override never silently picks a wrong ceiling)"
}

test_bad_max_extensions_env_fails_loud() {
    local rc=0
    LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS=x "$WALL" check --elapsed-min 10 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "non-integer MAX_EXTENSIONS exits 2"
}

test_unknown_subcommand_fails_loud() {
    local rc=0
    "$WALL" bogus >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "unknown subcommand exits 2"
}

test_no_subcommand_fails_loud() {
    local rc=0
    "$WALL" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "no subcommand exits 2"
}

# --- Leading-zero / octal rejection (regression for the review's blocking #1) --
# A digit string with a leading zero (030, 08, 010) feeds bash arithmetic as
# OCTAL: it either applies a silently-wrong threshold or crashes past the exit-2
# contract. Every numeric parameter must reject it, across all four inputs.

test_leading_zero_elapsed_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min 030 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --elapsed-min (030) exits 2, not an octal verdict"
}

test_leading_zero_elapsed_with_8_or_9_fails_loud() {
    # 08/09 are the crash variant ("value too great for base") — must be exit 2,
    # not the raw bash arithmetic error (exit 1) that bypasses die().
    local rc=0
    "$WALL" check --elapsed-min 09 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --elapsed-min with a 9 digit exits 2, does not crash"
}

test_leading_zero_extensions_fails_loud() {
    local rc=0
    "$WALL" check --elapsed-min 10 --level 3 --extensions-used 008 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --extensions-used (008) exits 2, does not crash"
}

test_leading_zero_timeout_env_fails_loud() {
    local rc=0
    LIBRARIAN_WORKFLOW_WALL_TIMEOUT=030 "$WALL" check --elapsed-min 6 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero TIMEOUT (030) exits 2, not a silent octal ceiling of 48"
}

test_leading_zero_max_extensions_env_fails_loud() {
    local rc=0
    LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS=010 "$WALL" check --elapsed-min 6 --level 3 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero MAX_EXTENSIONS (010) exits 2"
}

test_plain_zero_still_valid() {
    # `0` is the sole legitimate zero — the leading-zero rejection must not eat it.
    local out
    out="$("$WALL" check --elapsed-min 0 --level 3 --extensions-used 0)"
    assert_equals "continue" "$(val verdict "$out")" "elapsed 0 is a valid non-negative integer"
}

# --- extensions-used past the ceiling (regression for deferrable correctness#1) -

test_extensions_over_max_fails_loud() {
    # K > MAX_EXTENSIONS is invalid caller state; unchecked it inflated
    # next_deadline past the ceiling and returned `continue` forever.
    local rc=0 err
    err="$("$WALL" check --elapsed-min 25 --level 1 --extensions-used 5 2>&1 >/dev/null || true)"
    "$WALL" check --elapsed-min 25 --level 1 --extensions-used 5 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--extensions-used past MAX_EXTENSIONS exits 2"
    assert_contains "$err" "exceeds" "the over-ceiling extensions message names the invariant"
}

test_extensions_equal_max_is_valid() {
    # K == MAX_EXTENSIONS is the boundary and legitimate (the last granted window).
    local out
    out="$("$WALL" check --elapsed-min 25 --level 3 --extensions-used 1)"
    assert_equals "continue" "$(val verdict "$out")" "K == MAX_EXTENSIONS is valid (still inside the final window)"
}

# --- Integration: a bounded poll loop terminates a hung run (AC3, honest form) -
# Workflow/TaskOutput/TaskStop live in the model runtime and cannot be driven from
# a sandboxed bash test, so a true "TaskStop fires" fixture is not buildable here
# (see the script header + the PR's scope note). What IS testable — and is the
# mechanized core of the fix — is that a caller that consults the helper each poll
# ALWAYS reaches a `stop` in bounded time for a run that never finishes. This loop
# simulates a hung invocation (output never arrives) and asserts the decision
# oracle drives it to `stop`, never looping past the ceiling.
test_bounded_loop_reaches_stop_on_a_hung_run() {
    local elapsed=0 ext=0 verdict="" out iterations=0
    # Poll in 5-min steps up to a hard 200-min safety bound (10x the default
    # ceiling) — if the oracle ever failed to say `stop`, this bound catches the
    # runaway instead of hanging the test.
    while [ "$iterations" -lt 40 ]; do
        iterations=$((iterations + 1))
        out="$("$WALL" check --elapsed-min "$elapsed" --level 3 --extensions-used "$ext")"
        verdict="$(val verdict "$out")"
        case "$verdict" in
            stop) break ;;
            extend) ext="$(val extensions_used "$out")" ;;
            continue | checkpoint) : ;;
        esac
        elapsed=$((elapsed + 5))
    done
    assert_equals "stop" "$verdict" "a never-finishing L3 run is driven to stop by the per-poll oracle"
    # Default ceiling is 40 min; at a 5-min cadence the loop must stop by ~9 polls,
    # far under the safety bound — proving termination is the oracle's, not the cap's.
    assert_true "[ $elapsed -le 45 ]" "stop is reached at the ~40-min ceiling, not the 200-min safety bound"
}

run_test test_continue_below_checkpoint "continue below the checkpoint"
run_test test_continue_defaults_extensions_used_to_zero "--extensions-used defaults to 0"
run_test test_l3_auto_extends_at_checkpoint "L3 auto-extends at the checkpoint"
run_test test_l4_auto_extends_at_checkpoint "L4 auto-extends at the exact boundary"
run_test test_l1_l2_checkpoint_never_auto_extends "L1-L2 checkpoint, never auto-extend"
run_test test_stop_when_extensions_exhausted "stop when extensions exhausted (every level)"
run_test test_stop_at_exact_ceiling "stop at the exact ceiling"
run_test test_stop_when_already_past_ceiling_even_with_extension_left "stop past the ceiling even with an extension left"
run_test test_timeout_override_moves_checkpoint "TIMEOUT override moves the checkpoint"
run_test test_max_extensions_override_raises_ceiling "MAX_EXTENSIONS override raises the ceiling"
run_test test_zero_extensions_stops_at_first_checkpoint "MAX_EXTENSIONS=0 stops at the first checkpoint"
run_test test_missing_elapsed_fails_loud "missing --elapsed-min -> exit 2"
run_test test_noninteger_elapsed_fails_loud "non-integer --elapsed-min -> exit 2"
run_test test_negative_elapsed_fails_loud "negative --elapsed-min -> exit 2"
run_test test_missing_level_fails_loud "missing --level -> exit 2"
run_test test_bad_level_fails_loud "bad --level -> exit 2"
run_test test_negative_extensions_fails_loud "negative --extensions-used -> exit 2"
run_test test_bad_timeout_env_fails_loud "bad TIMEOUT env -> exit 2"
run_test test_bad_max_extensions_env_fails_loud "bad MAX_EXTENSIONS env -> exit 2"
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
run_test test_bounded_loop_reaches_stop_on_a_hung_run "bounded poll loop drives a hung run to stop (AC3)"

generate_report
