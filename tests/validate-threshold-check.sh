#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/threshold-check.sh (issue #588).
#
# The library holds the bounded-wait verdict arithmetic shared by
# ci-wait-timeout.sh and workflow-wall-timeout.sh. Those two wrapper suites drive
# it end-to-end through their own CLIs and are the primary coverage — the
# decision table, the env overrides, and every fail-loud exit are pinned there,
# twice, at two different threshold pairs.
#
# What they CANNOT reach is what this file covers: behavior the library
# documents but no wrapper's CLI surface exposes. Concretely, tc_opt promises
# that "a value that itself starts with `--` is treated as absent" — the guard
# that stops `check --elapsed-min --level 3` from silently consuming `--level` as
# the elapsed value and then computing a verdict from a nonsense input. Neither
# wrapper suite passes such an argv, so without this file that guard is
# untested: delete it and both suites still pass green.
#
# The unit tests below SOURCE the library directly rather than shelling out to a
# wrapper, so a regression is attributed to the library instead of surfacing as a
# confusing failure in one arbitrary wrapper's suite.
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/plugins/workflow/scripts/threshold-check.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The library is a pure function collection with no top-level side effects, so
# sourcing it here is safe and is the point — these are unit tests.
# shellcheck source=plugins/workflow/scripts/threshold-check.sh
source "$LIB"

test_suite "threshold-check.sh (#588)"

# --- tc_opt ------------------------------------------------------------------

test_opt_finds_a_value() {
    local got
    got="$(tc_opt --elapsed-min -- check --elapsed-min 17 --level 3)"
    assert_equals "17" "$got" "tc_opt returns the token following the flag"
}

test_opt_missing_flag_returns_empty_and_nonzero() {
    local got rc=0
    got="$(tc_opt --extensions-used -- check --elapsed-min 17 --level 3)" || rc=$?
    assert_equals "1" "$rc" "an absent flag returns non-zero"
    assert_equals "" "$got" "an absent flag yields an empty value"
}

# THE case neither wrapper suite reaches. `--elapsed-min --level 3` must treat
# the elapsed value as ABSENT (so the caller's fail-loud branch fires) rather
# than swallowing `--level` as the value — which would leave --level itself
# unparsed too, and turn a typo into a confidently wrong verdict.
test_opt_treats_a_flag_shaped_value_as_absent() {
    local got rc=0
    got="$(tc_opt --elapsed-min -- check --elapsed-min --level 3)" || rc=$?
    assert_equals "" "$got" \
        "a value that itself starts with -- is treated as absent, not consumed"
    # Found-but-empty: the flag WAS present, so the status is 0 while the value
    # is empty. The caller keys on the empty value, not the status — assert both
    # halves so a future change to either is visible here.
    assert_equals "0" "$rc" "the flag itself was still seen (found, with an empty value)"

    # And the end-to-end consequence, through the real CLI: this argv must
    # fail loud, never produce a verdict.
    local out err erc=0
    out="$("$REPO_ROOT/plugins/workflow/scripts/ci-wait-timeout.sh" check \
        --elapsed-min --level 3 2>/dev/null)" || erc=$?
    err="$("$REPO_ROOT/plugins/workflow/scripts/ci-wait-timeout.sh" check \
        --elapsed-min --level 3 2>&1 >/dev/null || true)"
    assert_equals "2" "$erc" "the flag-shaped value exits 2 rather than computing a verdict"
    assert_not_contains "$out" "verdict=" "no verdict is emitted for the malformed argv"
    assert_contains "$err" "needs --elapsed-min" "the error names the flag whose value went missing"
}

test_opt_first_occurrence_wins() {
    local got
    got="$(tc_opt --level -- check --level 2 --level 4)"
    assert_equals "2" "$got" "the first occurrence of a repeated flag wins"
}

test_opt_ignores_a_bare_flag_name_in_a_value_position() {
    # A value equal to the flag name must not confuse the scan.
    local got
    got="$(tc_opt --level -- check --elapsed-min 5 --level 3)"
    assert_equals "3" "$got" "the flag is matched by name, not by position"
}

# --- tc_is_nonneg_int --------------------------------------------------------

test_is_nonneg_int_accepts_canonical_integers() {
    local v
    for v in 0 1 7 15 20 45 100 999; do
        assert_true "tc_is_nonneg_int $v" "$v is a canonical non-negative integer"
    done
}

test_is_nonneg_int_rejects_non_integers() {
    local v
    for v in "" "x" "1x" "1.5" "-1" " 1" "1 " "+1"; do
        assert_true "! tc_is_nonneg_int '$v'" "'$v' is rejected"
    done
}

# The octal guard, unit-tested at the source. Both wrapper suites cover it via
# their CLIs; pinning it here as well is deliberate, because this is the one
# predicate whose failure mode is a SILENTLY WRONG number rather than a crash.
test_is_nonneg_int_rejects_leading_zeros() {
    local v
    for v in 00 01 08 09 010 030 0100; do
        assert_true "! tc_is_nonneg_int $v" \
            "$v is rejected (bash would read it as octal, or crash on 08/09)"
    done
    # `0` itself is the sole legitimate zero and must survive the rejection.
    assert_true "tc_is_nonneg_int 0" "plain 0 is still accepted"
}

# --- tc_valid_level ----------------------------------------------------------

test_valid_level_accepts_1_through_4() {
    local v
    for v in 1 2 3 4; do
        assert_true "tc_valid_level $v" "level $v is valid"
    done
}

test_valid_level_rejects_everything_else() {
    local v
    for v in 0 5 9 "" "x" "-1" "1.0" "01"; do
        assert_true "! tc_valid_level '$v'" "level '$v' is rejected"
    done
}

# --- Wrapper independence ----------------------------------------------------

# The library keeps per-call identity in TC_* globals. If a wrapper's name or var
# names leaked between invocations, one loop's error messages would name the
# other's variables — actively misleading an operator about which knob to set.
# Drive both real CLIs in sequence and assert each names only its own.
test_wrappers_do_not_leak_identity() {
    local ci_err wall_err
    ci_err="$("$REPO_ROOT/plugins/workflow/scripts/ci-wait-timeout.sh" check \
        --elapsed-min 10 --level 9 2>&1 >/dev/null || true)"
    wall_err="$("$REPO_ROOT/plugins/workflow/scripts/workflow-wall-timeout.sh" check \
        --elapsed-min 10 --level 9 2>&1 >/dev/null || true)"

    assert_contains "$ci_err" "ci-wait-timeout" "the CI-wait CLI names itself"
    assert_not_contains "$ci_err" "workflow-wall-timeout" \
        "the CI-wait CLI does not name its sibling"
    assert_contains "$wall_err" "workflow-wall-timeout" "the wall-timeout CLI names itself"
    assert_not_contains "$wall_err" "ci-wait-timeout" \
        "the wall-timeout CLI does not name its sibling"

    # Same for the env-var names each reports in a bad-override message.
    local ci_env wall_env
    ci_env="$(LIBRARIAN_CI_WAIT_TIMEOUT=0 \
        "$REPO_ROOT/plugins/workflow/scripts/ci-wait-timeout.sh" check \
        --elapsed-min 10 --level 3 2>&1 >/dev/null || true)"
    wall_env="$(LIBRARIAN_WORKFLOW_WALL_TIMEOUT=0 \
        "$REPO_ROOT/plugins/workflow/scripts/workflow-wall-timeout.sh" check \
        --elapsed-min 10 --level 3 2>&1 >/dev/null || true)"
    assert_contains "$ci_env" "LIBRARIAN_CI_WAIT_TIMEOUT" \
        "the CI-wait CLI reports the var the operator actually set"
    assert_not_contains "$ci_env" "LIBRARIAN_WORKFLOW_WALL_TIMEOUT" \
        "the CI-wait CLI does not report its sibling's var"
    assert_contains "$wall_env" "LIBRARIAN_WORKFLOW_WALL_TIMEOUT" \
        "the wall-timeout CLI reports its own var"
    assert_not_contains "$wall_env" "LIBRARIAN_CI_WAIT_TIMEOUT" \
        "the wall-timeout CLI does not report its sibling's var"
}

# The library is SOURCED, so it must not run anything or exit on its own — a
# stray top-level statement would fire inside every wrapper (and inside this
# suite) at source time.
test_library_sources_cleanly_with_no_output() {
    local out rc=0
    out="$(command bash -c "set -euo pipefail; . '$LIB'; command printf 'SOURCED'" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "sourcing the library succeeds under set -euo pipefail"
    assert_equals "SOURCED" "$out" "sourcing produces no output and runs nothing"
}

run_test test_opt_finds_a_value "tc_opt returns a flag's value"
run_test test_opt_missing_flag_returns_empty_and_nonzero "tc_opt reports an absent flag"
run_test test_opt_treats_a_flag_shaped_value_as_absent "tc_opt treats a --flag-shaped value as absent"
run_test test_opt_first_occurrence_wins "tc_opt takes the first occurrence of a repeated flag"
run_test test_opt_ignores_a_bare_flag_name_in_a_value_position "tc_opt matches by name, not position"
run_test test_is_nonneg_int_accepts_canonical_integers "tc_is_nonneg_int accepts canonical integers"
run_test test_is_nonneg_int_rejects_non_integers "tc_is_nonneg_int rejects non-integers"
run_test test_is_nonneg_int_rejects_leading_zeros "tc_is_nonneg_int rejects leading zeros (octal guard)"
run_test test_valid_level_accepts_1_through_4 "tc_valid_level accepts 1-4"
run_test test_valid_level_rejects_everything_else "tc_valid_level rejects everything else"
run_test test_wrappers_do_not_leak_identity "the two wrappers do not leak identity into each other"
run_test test_library_sources_cleanly_with_no_output "the library sources cleanly and runs nothing"

generate_report
