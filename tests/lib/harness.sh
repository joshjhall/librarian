#!/usr/bin/env bash
# Minimal, self-contained test harness for the librarian quality gates.
#
# This is a dependency-light vendoring of just the assertion + reporting
# surface the relocated skill/agent structural gates use. It deliberately
# does NOT pull in the containers test framework (which is Docker-coupled and
# sources eight assertion modules). Everything the gates call lives here:
#
#   test_suite / run_test / generate_report   — suite + per-test tracking
#   assert_true                               — eval a command, message heuristic
#   assert_equals / assert_not_empty          — value assertions
#   assert_contains                           — substring assertion
#   assert_valid_json                         — no-eval JSON validation (untrusted-safe)
#   assert_file_exists                        — filesystem assertion
#   assert_file_contains / _not_contains      — grep-based file assertions
#   skip_test                                 — record a skipped test
#
# Semantics match the containers framework so the relocated gate bodies run
# unmodified. Pure bash + coreutils; no external deps. Full paths / the
# `command` builtin are used for coreutils per project convention.

set -euo pipefail

# --- Counters / state -------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_STATUS=""
SUITE_NAME=""

# Color output only when stdout is a TTY.
if [ -t 1 ]; then
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_BOLD=$'\033[1m'
    _C_RESET=$'\033[0m'
else
    _C_RED=""
    _C_GREEN=""
    _C_YELLOW=""
    _C_BOLD=""
    _C_RESET=""
fi

# --- Suite / test lifecycle -------------------------------------------------

test_suite() {
    SUITE_NAME="$1"
    printf '%s\n' "${_C_BOLD}=== ${SUITE_NAME} ===${_C_RESET}"
}

# run_test <function> <description>
# Resets per-test status, runs the function, and records pass/fail/skip.
run_test() {
    local test_func="$1"
    local test_desc="${2:-$test_func}"

    TEST_STATUS=""
    TESTS_RUN=$((TESTS_RUN + 1))

    printf '  %s ... ' "$test_desc"

    # A test body that returns non-zero without calling an assertion still
    # counts as a failure (mirrors the framework's set -e-tolerant behavior:
    # assertions flip TEST_STATUS, the return code is a backstop).
    if "$test_func"; then
        :
    else
        if [ "$TEST_STATUS" != "failed" ] && [ "$TEST_STATUS" != "skipped" ]; then
            TEST_STATUS="failed"
            printf '%s\n' "${_C_RED}FAIL${_C_RESET} (test body returned non-zero)"
        fi
    fi

    if [ "$TEST_STATUS" = "skipped" ]; then
        : # already reported by skip_test
    elif [ "$TEST_STATUS" = "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%s\n' "${_C_GREEN}PASS${_C_RESET}"
    fi
}

# Internal: record a failing assertion. Prints details; flips TEST_STATUS.
# Only the first failure of a test prints the FAIL header so output stays
# readable; subsequent failures within the same test add detail lines.
_fail() {
    local message="$1"
    shift
    if [ "$TEST_STATUS" != "failed" ]; then
        printf '%s\n' "${_C_RED}FAIL${_C_RESET}"
        TEST_STATUS="failed"
    fi
    printf '      %s%s%s\n' "${_C_RED}" "$message" "${_C_RESET}"
    local line
    for line in "$@"; do
        printf '        %s\n' "$line"
    done
}

skip_test() {
    local reason="$1"
    printf '%s\n' "${_C_YELLOW}SKIP${_C_RESET} (${reason})"
    if [ "$TEST_STATUS" != "skipped" ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    fi
    TEST_STATUS="skipped"
}

# --- Assertions -------------------------------------------------------------

# assert_true <command...> [message]
# Evaluates the command string. The containers framework treats the last
# argument as the failure message when it contains whitespace or starts with
# an uppercase letter; we replicate that heuristic so gate bodies are portable.
assert_true() {
    local all_args=("$@")
    local last="${all_args[*]: -1}"
    local message="Command should succeed"
    local cmd

    if [[ "$last" =~ [[:space:]] ]] || [[ "$last" =~ ^[A-Z] ]]; then
        message="$last"
        # Command is everything except the last argument.
        local n=$((${#all_args[@]} - 1))
        if [ "$n" -le 0 ]; then
            cmd=""
        else
            cmd="${all_args[*]:0:$n}"
        fi
    else
        cmd="${all_args[*]}"
    fi

    if eval "$cmd" >/dev/null 2>&1; then
        return 0
    else
        _fail "$message" "Command:  $cmd"
        return 0 # do not abort the test body; one failed assertion != stop
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    if [ "$expected" = "$actual" ]; then
        return 0
    fi
    _fail "$message" "Expected: '$expected'" "Actual:   '$actual'"
    return 0
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"
    if [ -n "$value" ]; then
        return 0
    fi
    _fail "$message" "Value:    (empty)"
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    fi
    _fail "$message" "String:   '$haystack'" "Missing:  '$needle'"
    return 0
}

# assert_not_contains <haystack> <needle> [message]
# The negative of assert_contains. Pure-bash glob, no eval — safe for
# attacker-influenceable strings (golem-gate-watch.sh and lint-action-pins.sh
# previously open-coded this with `case`-globs for exactly that reason).
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"
    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    fi
    _fail "$message" "String:   '$haystack'" "Unexpected: '$needle'"
    return 0
}

# assert_valid_json <value> [message]
# Asserts <value> is well-formed JSON. Takes the value as a real argument (no
# eval, no shell re-quoting) so it is safe for attacker-influenceable strings —
# unlike building `printf '%s' '$value' | jq -e .` for assert_true, where an
# embedded single quote would close the surrounding '...' early inside the
# eval'd command and let following metacharacters run. Skips (passes) when jq is
# absent; call sites already gate their suites on jq.
#
# `jq empty` is a syntax-only parse check (reads input, emits nothing, exits
# non-zero only on malformed JSON) — unlike `jq -e .`, whose exit status keys off
# the *truthiness* of the output, so the valid scalars `false`/`null` would be
# misreported as invalid.
assert_valid_json() {
    local value="$1"
    local message="${2:-Value should be valid JSON}"
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    if printf '%s' "$value" | jq empty >/dev/null 2>&1; then
        return 0
    fi
    _fail "$message" "Value:    '$(printf '%s' "$value" | command head -3)'"
    return 0
}

assert_exit() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Exit code should match}"
    if [ "$expected" = "$actual" ]; then
        return 0
    fi
    _fail "$message" "Expected exit: $expected" "Actual exit:   $actual"
    return 0
}

assert_output_empty() {
    local output="$1"
    local message="${2:-Output should be empty}"
    if [ -z "$output" ]; then
        return 0
    fi
    _fail "$message" "Output:   '$(printf '%s' "$output" | command head -3)'"
    return 0
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"
    if [ -f "$file" ]; then
        return 0
    fi
    _fail "$message" "File:     '$file'"
    return 0
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should contain pattern}"
    if [ ! -f "$file" ]; then
        _fail "$message" "File:     '$file'" "Error:    File does not exist"
        return 0
    fi
    if command grep -q -- "$pattern" "$file" 2>/dev/null; then
        return 0
    fi
    _fail "$message" "File:     '$file'" "Pattern:  '$pattern'"
    return 0
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should not contain pattern}"
    if [ ! -f "$file" ]; then
        # A non-existent file trivially does not contain the pattern.
        return 0
    fi
    if ! command grep -q -- "$pattern" "$file" 2>/dev/null; then
        return 0
    fi
    local match
    match=$(command grep -n -- "$pattern" "$file" 2>/dev/null | command head -1)
    _fail "$message" "File:     '$file'" "Pattern:  '$pattern'" "Match:    $match"
    return 0
}

# --- Reporting --------------------------------------------------------------

# generate_report prints a summary and exits non-zero if any test failed.
generate_report() {
    printf '\n%s\n' "${_C_BOLD}Summary${_C_RESET}"
    printf '  Total:   %d\n' "$TESTS_RUN"
    printf '  Passed:  %s%d%s\n' "${_C_GREEN}" "$TESTS_PASSED" "${_C_RESET}"
    printf '  Failed:  %s%d%s\n' "${_C_RED}" "$TESTS_FAILED" "${_C_RESET}"
    printf '  Skipped: %s%d%s\n' "${_C_YELLOW}" "$TESTS_SKIPPED" "${_C_RESET}"

    [ "$TESTS_FAILED" -eq 0 ]
}
