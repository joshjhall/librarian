#!/usr/bin/env bash
# bounded_run BEHAVIOR (issue #961).
#
# tests/lint-bounded-run-sync.sh pins that the two copies are byte-identical and
# depend on no GNU coreutils. Neither is a claim that the bound WORKS — that was
# the gap #961 fell through: the helper was well-tested as text and untested as
# behaviour, so a bound that stopped bounding was invisible for as long as it
# took someone to sit through a 15-minute stall.
#
# THE DEFECT THIS PINS. `bounded_run` kills the process it is bounding, but a
# command substitution does not return until every descendant has closed the
# pipe's write end. The subject used to inherit the caller's stdout — which
# inside `out="$(bounded_run …)"` IS that pipe — so any grandchild outliving the
# signal blocked `$( )` indefinitely, and the 124-normalization one line later
# never ran.
#
# Measured on PR #963's CI: a --watch case PASSed at 20:01:27, the next line
# appeared at 20:16:27, and the job died at its timeout-minutes cap. On an idle
# runner: contention makes it likelier, it is not required. The holders were
# `sleep 3600` watchdogs reparented to init — forked by bounded_run itself.
#
# EVERY CASE HERE IS OUTER-BOUNDED. A regression makes these hang by
# construction, and a test that can wedge the suite it guards is worse than the
# bug (validate-golem-watch.sh § the retired INT case). The outer bound is
# `timeout` where present, and the case SKIPS where it is not — deliberately the
# one place in this repo that may depend on GNU timeout, because bounding a test
# OF bounded_run with bounded_run would be circular.
#
# Pure bash + coreutils. bash-3.2 clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

REAL_BASH="$(command -v bash)"
BR="$REPO_ROOT/bin/bounded-run.sh"

test_suite "bounded_run behavior (#961)"

# outer_bound <secs> <script> — run <script> under an INDEPENDENT bound and
# print "TIMEDOUT" if it did not finish. Uses timeout(1) on purpose; see header.
outer_bound() {
    local secs="$1" script="$2" rc=0
    command timeout "$secs" "$REAL_BASH" -c "$script" 2>&1 || rc=$?
    [ "$rc" = "124" ] && command printf 'TIMEDOUT\n'
    return 0
}

have_outer_bound() { command -v timeout >/dev/null 2>&1; }

# --- THE #961 CASE ----------------------------------------------------------

# A subject that spawns a child outliving SIGTERM. Before the fix this hung
# until the grandchild exited on its own; after it, the substitution returns as
# soon as bounded_run does.
#
# MUTATION-VERIFIED (AC1): reverting the redirect in bin/bounded-run.sh to a
# bare `"$@" &` makes this case report TIMEDOUT rather than passing — confirmed
# by hand before this test was committed, and reproducible by making that one
# edit. Without that check the case would be green against both the fixed and
# the broken helper, which is the failure mode it exists to prevent.
test_capture_returns_when_a_grandchild_survives() {
    if ! have_outer_bound; then
        skip_test "timeout(1) unavailable to bound the TEST itself (see header)"
        return 0
    fi
    local out
    out="$(outer_bound 30 "
        source '$BR'
        # The subject ignores TERM and leaves a long-lived child behind.
        captured=\"\$(bounded_run 2 $REAL_BASH -c 'sleep 300 & trap \"\" TERM; sleep 60' 2>&1)\"
        printf 'rc=%s\n' \"\$?\"
    ")"
    assert_not_contains "$out" "TIMEDOUT" \
        "the command substitution RETURNS when a grandchild outlives the bound (#961: this hung ~15 min on CI)"
    # AC2: the 124-normalization is reached, not merely skipped past. It sits one
    # line after the wait, so a hang means it never runs — asserting the code is
    # what proves the branch is live.
    assert_contains "$out" "rc=124" \
        "the bound is reported as 124, proving the normalization after the wait is reachable"
}

# The orphan must not outlive the call either — every interrupted run used to
# leave an hour-long `sleep 3600` behind, and a later suite inheriting that
# descriptor stalled for the remainder of a sleep it had nothing to do with.
test_no_long_lived_orphan_holds_the_pipe() {
    if ! have_outer_bound; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi
    local out
    out="$(outer_bound 30 "
        source '$BR'
        captured=\"\$(bounded_run 2 $REAL_BASH -c 'sleep 120 & sleep 30' 2>&1)\"
        printf 'done\n'
    ")"
    assert_contains "$out" "done" \
        "a backgrounded grandchild does not hold the capture open"
    assert_not_contains "$out" "TIMEDOUT" "the call completes within the outer bound"
}

# --- the properties the fix must not break ----------------------------------

test_fast_command_is_not_delayed() {
    if ! have_outer_bound; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi
    # The note-(1) property: a fast command must not be held for the full bound.
    local out
    out="$(outer_bound 20 "
        source '$BR'
        s=\$(date +%s)
        captured=\"\$(bounded_run 15 $REAL_BASH -c 'printf hello' 2>&1)\"
        e=\$(date +%s)
        printf 'elapsed=%s out=%s\n' \"\$((e - s))\" \"\$captured\"
    ")"
    assert_not_contains "$out" "TIMEDOUT" "a fast command returns promptly"
    assert_contains "$out" "out=hello" "the subject's stdout still reaches the caller"
    assert_true "! printf '%s' \"$out\" | command grep -qE 'elapsed=(1[0-9]|[2-9][0-9])'" \
        "a fast command is NOT held for the full bound (note 1)"
}

test_exit_status_is_the_subjects() {
    if ! have_outer_bound; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi
    local out
    out="$(outer_bound 20 "
        source '$BR'
        captured=\"\$(bounded_run 10 $REAL_BASH -c 'printf x; exit 3' 2>&1)\"
        printf 'rc=%s out=%s\n' \"\$?\" \"\$captured\"
    ")"
    assert_contains "$out" "rc=3" "an unbounded command's own exit status is returned"
    assert_contains "$out" "out=x" "its output is relayed"
}

test_stderr_is_relayed() {
    if ! have_outer_bound; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi
    # The relay merges stdout and stderr; callers in this repo all use 2>&1.
    local out
    out="$(outer_bound 20 "
        source '$BR'
        captured=\"\$(bounded_run 10 $REAL_BASH -c 'printf oops >&2' 2>&1)\"
        printf 'out=%s\n' \"\$captured\"
    ")"
    assert_contains "$out" "out=oops" "the subject's stderr reaches a 2>&1 caller"
}

run_test test_capture_returns_when_a_grandchild_survives \
    "the capture returns when a grandchild outlives the bound (#961)"
run_test test_no_long_lived_orphan_holds_the_pipe \
    "no backgrounded grandchild holds the capture open (#961)"
run_test test_fast_command_is_not_delayed \
    "a fast command is not held for the full bound (note 1)"
run_test test_exit_status_is_the_subjects \
    "the subject's own exit status is returned"
run_test test_stderr_is_relayed \
    "the subject's stderr is relayed to a 2>&1 caller"

generate_report
