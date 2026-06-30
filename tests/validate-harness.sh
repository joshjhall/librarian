#!/usr/bin/env bash
# Self-test for the shared test harness (tests/lib/harness.sh).
#
# Every other gate trusts harness.sh's assertions, but the harness itself had no
# test — most notably assert_true's argument-parsing heuristic (the last arg is
# the failure *message* when it contains whitespace or starts with an uppercase
# letter; otherwise every arg is part of the *command*). A silent regression
# there would weaken every gate at once while the suite still reported green.
#
# Testing assertions against themselves has one wrinkle: by design every
# assert_* returns 0 even on failure — it signals via _fail (stdout) and
# TEST_STATUS, not the exit code — so a probe that is *meant* to fail cannot be
# detected by its return status, and run directly would corrupt this suite's own
# counters. So each probe runs inside a command-substitution subshell
# (capture_assert): its stdout is captured for inspection and its global
# mutations are discarded, leaving the live suite's counters/TEST_STATUS intact.
#
# Pure bash + coreutils; no external deps. Uses the harness it is testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Harness self-test"

# --- Probe helper -----------------------------------------------------------

# capture_assert <assertion> [args...]
# Run an assertion in an isolated subshell and echo whatever it wrote to stdout.
# A passing assertion writes nothing; a failing one writes its _fail block. The
# subshell isolates the assertion's global side effects (counters, TEST_STATUS)
# from the live suite, so a deliberately-failing probe here is harmless.
capture_assert() {
    ("$@") 2>&1
}

# --- assert_true heuristic --------------------------------------------------

# A last argument containing whitespace is taken as the failure message, leaving
# the command intact (here: the bare `false`, which fails and surfaces the msg).
#
# The message text alone is a weak signal — it is echoed in the "Command:" line
# too if the heuristic FAILS to strip it. Two tight discriminators prove the
# heuristic actually fired: the default message must be ABSENT (a custom message
# replaced it), and the command line must NOT carry the message text.
test_assert_true_whitespace_is_message() {
    local out
    out="$(capture_assert assert_true false "this message has spaces")"
    assert_contains "$out" "this message has spaces" \
        "whitespace last-arg is treated as the message"
    assert_not_contains "$out" "Command should succeed" \
        "the custom message replaces the default (heuristic fired)"
    assert_not_contains "$out" "false this message" \
        "the message is stripped from the evaluated command"
}

# A single-token last argument starting with an uppercase letter is also a
# message (no whitespace needed). Same tight discriminators as above.
test_assert_true_uppercase_is_message() {
    local out
    out="$(capture_assert assert_true false Uppercaseword)"
    assert_contains "$out" "Uppercaseword" \
        "uppercase-initial last-arg is treated as the message"
    assert_not_contains "$out" "Command should succeed" \
        "the custom message replaces the default (heuristic fired)"
    assert_not_contains "$out" "false Uppercaseword" \
        "the message is stripped from the evaluated command"
}

# A lowercase single-token last argument has neither trigger, so it stays part
# of the command and the default message is used.
test_assert_true_lowercase_is_command() {
    local out
    out="$(capture_assert assert_true false lowercaseword)"
    assert_contains "$out" "Command:  false lowercaseword" \
        "lowercase last-arg stays part of the evaluated command"
    assert_contains "$out" "Command should succeed" \
        "the default message is used when no message arg is detected"
}

# A succeeding command produces no failure output — and proves the message arg
# was correctly removed before eval (eval'ing `true "msg"` here would also pass,
# so pair this with the stripping checks above for full confidence).
test_assert_true_pass_is_silent() {
    local out
    out="$(capture_assert assert_true true "Should pass quietly")"
    assert_equals "" "$out" "a passing assert_true writes nothing"
}

# --- assert_equals ----------------------------------------------------------

test_assert_equals_pass_is_silent() {
    local out
    out="$(capture_assert assert_equals foo foo)"
    assert_equals "" "$out" "equal values produce no output"
}

test_assert_equals_fail_reports() {
    local out
    out="$(capture_assert assert_equals foo bar "values differ")"
    assert_contains "$out" "values differ" "custom message is shown on mismatch"
    assert_contains "$out" "Expected: 'foo'" "expected value is reported"
    assert_contains "$out" "Actual:   'bar'" "actual value is reported"
}

# --- assert_not_empty -------------------------------------------------------

test_assert_not_empty_pass_is_silent() {
    local out
    out="$(capture_assert assert_not_empty "x")"
    assert_equals "" "$out" "a non-empty value produces no output"
}

test_assert_not_empty_fail_reports() {
    local out
    out="$(capture_assert assert_not_empty "" "should have a value")"
    assert_contains "$out" "should have a value" "empty value triggers the message"
}

# --- assert_contains --------------------------------------------------------

test_assert_contains_pass_is_silent() {
    local out
    out="$(capture_assert assert_contains "hello world" "lo wo")"
    assert_equals "" "$out" "a present substring produces no output"
}

test_assert_contains_fail_reports() {
    local out
    out="$(capture_assert assert_contains "hello world" "zzz" "needle missing")"
    assert_contains "$out" "needle missing" "absent substring triggers the message"
}

# --- assert_not_contains (newly added) --------------------------------------

test_assert_not_contains_pass_is_silent() {
    local out
    out="$(capture_assert assert_not_contains "hello world" "zzz")"
    assert_equals "" "$out" "an absent substring produces no output"
}

test_assert_not_contains_fail_reports() {
    local out
    out="$(capture_assert assert_not_contains "hello world" "lo wo" "needle present")"
    assert_contains "$out" "needle present" "present substring triggers the message"
    assert_contains "$out" "Unexpected: 'lo wo'" "the unexpected substring is reported"
}

# --- skip_test --------------------------------------------------------------

# skip_test mutates TESTS_SKIPPED and TEST_STATUS; run it in a subshell with
# freshly-reset state and echo the resulting values so the live counters are not
# touched.
test_skip_test_increments_counter() {
    local out
    out="$(
        TESTS_SKIPPED=0 TEST_STATUS=""
        skip_test "no reason"
        printf 'SKIPPED=%d STATUS=%s' "$TESTS_SKIPPED" "$TEST_STATUS"
    )"
    assert_contains "$out" "SKIP" "skip_test prints a SKIP marker"
    assert_contains "$out" "no reason" "skip_test prints the reason"
    assert_contains "$out" "SKIPPED=1" "skip_test increments TESTS_SKIPPED"
    assert_contains "$out" "STATUS=skipped" "skip_test sets TEST_STATUS=skipped"
}

# --- Run all tests ----------------------------------------------------------

run_test test_assert_true_whitespace_is_message "assert_true: whitespace last-arg is the message"
run_test test_assert_true_uppercase_is_message "assert_true: uppercase-initial last-arg is the message"
run_test test_assert_true_lowercase_is_command "assert_true: lowercase last-arg stays part of the command"
run_test test_assert_true_pass_is_silent "assert_true: a passing command is silent"

run_test test_assert_equals_pass_is_silent "assert_equals: equal values are silent"
run_test test_assert_equals_fail_reports "assert_equals: mismatch reports expected/actual"

run_test test_assert_not_empty_pass_is_silent "assert_not_empty: non-empty is silent"
run_test test_assert_not_empty_fail_reports "assert_not_empty: empty reports the message"

run_test test_assert_contains_pass_is_silent "assert_contains: present substring is silent"
run_test test_assert_contains_fail_reports "assert_contains: absent substring reports the message"

run_test test_assert_not_contains_pass_is_silent "assert_not_contains: absent substring is silent"
run_test test_assert_not_contains_fail_reports "assert_not_contains: present substring reports the message"

run_test test_skip_test_increments_counter "skip_test: increments TESTS_SKIPPED and sets TEST_STATUS"

generate_report
