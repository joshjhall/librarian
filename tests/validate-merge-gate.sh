#!/usr/bin/env bash
# merge-gate composition gate (#947).
#
# `merge-gate` is the single required branch-protection check: it is what
# "everything that should have run, ran and passed" means for this repo. Nothing
# pinned its composition, so the job that decides whether a PR may merge was
# itself the least-verified thing in the tree. #947 promoted `bsd-probe` into its
# `needs:` — a promotion that would have been unverified in exactly the way it
# exists to prevent, since a later edit could drop the job back out while every
# shard stayed green and the gate went on reporting success.
#
# WHY STRUCTURAL AND NOT BEHAVIORAL. The gate's logic runs only inside GitHub
# Actions, where `needs.<job>.result` is supplied by the runner; there is no
# local way to make a job report `skipped`. So this reads the workflow as text
# and asserts the wiring. That is a real limitation, stated rather than papered
# over: it can prove `bsd-probe` is in `needs:` and that the refusal branch
# exists, not that Actions evaluates them as expected. The end-to-end proof is
# the PR's own merge-gate run, which consumes the new result for real.
#
# COMMENTS ARE EXCLUDED FROM EVERY MATCH. This file's prose names every symbol it
# checks — as does ci.yml's own rationale block, at length. A raw file-contains
# check would therefore pass with the actual wiring deleted, the prose alone
# keeping it green. That is the mutation-round lesson recorded in
# validate-coverage-runner.sh's test_ci_sets_required_flag, and the same shape as
# a comment asserting a property the code lacks. Every assertion below strips
# comment lines first and anchors to the owning block.
#
# Pure bash + coreutils + grep/awk; no network, no YAML parser. Uses the shared
# harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CI="$REPO_ROOT/.github/workflows/ci.yml"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "merge-gate composition (#947)"

# --- helpers ----------------------------------------------------------------

# merge_gate_block — the `merge-gate:` job's own lines, comments stripped.
#
# Anchored from the job key to the next top-level job key (a 2-space-indented
# `<name>:`), so a match cannot drift in from a neighbouring job. Everything
# below reads this, never the whole file.
merge_gate_block() {
    command grep -v '^[[:space:]]*#' "$CI" 2>/dev/null |
        command awk '
            /^[[:space:]]{2}merge-gate:[[:space:]]*$/ { inb = 1; next }
            inb && /^[[:space:]]{2}[a-zA-Z_-]+:[[:space:]]*$/ { inb = 0 }
            inb { print }'
}

# --- cases ------------------------------------------------------------------

# The vacuity guard, first and on its own. Every other case scopes to
# merge_gate_block, so if that anchor ever matches nothing — the job renamed,
# the indentation changed — they would all trivially "pass" against an empty
# string. Failing loudly here is what stops this gate from going silently inert,
# which is the same failure class the gate itself was added to close.
test_anchor_is_not_vacuous() {
    local block
    assert_file_exists "$CI" "ci.yml exists"

    block="$(merge_gate_block)"
    assert_not_empty "$block" \
        "The merge-gate job block is found (else every assertion below is vacuous)"
    assert_contains "$block" "runs-on:" \
        "The extracted block looks like a job definition, not stray text"
}

# AC3: bsd-probe is actually in the needs: list. This is the promotion itself.
test_bsd_probe_is_in_needs() {
    local needs_line
    needs_line="$(merge_gate_block |
        command grep -E '^[[:space:]]*needs:' || true)"

    assert_not_empty "$needs_line" "merge-gate declares a needs: list"
    assert_contains "$needs_line" "bsd-probe" \
        "merge-gate's needs: includes bsd-probe — the #947 promotion"
    # The pre-existing dependencies must survive the promotion; adding one gate
    # by dropping another would trade one blind spot for another.
    assert_contains "$needs_line" "validate-manifests" \
        "merge-gate's needs: still includes validate-manifests"
    assert_contains "$needs_line" "quality-gates" \
        "merge-gate's needs: still includes quality-gates"
}

# A needs: entry alone does not gate anything — Actions would still run the job
# and the step could ignore the result entirely. The env binding is what carries
# the result into the check.
test_bsd_result_is_bound_from_needs() {
    local block
    block="$(merge_gate_block)"

    assert_contains "$block" 'BSD_RESULT: ${{ needs.bsd-probe.result }}' \
        "BSD_RESULT is bound to needs.bsd-probe.result (env, not shell-interpolated)"
}

# AC4, the load-bearing half: the skip tolerance must be conditional on a fork
# PR. An unconditional `skipped` acceptance would let bsd-probe silently stop
# running on same-repo pushes and still pass the gate — the inert-gate shape
# (#538/#571) rebuilt inside the gate meant to prevent it.
#
# Asserted on the shared check_gate helper rather than a per-job branch: that
# helper is the single place the disposition is decided, so pinning it covers
# quality-gates and bsd-probe at once.
test_skip_is_tolerated_only_on_a_fork_pr() {
    local block skip_branch
    block="$(merge_gate_block)"

    skip_branch="$(printf '%s\n' "$block" |
        command grep -E '\[ "\$2" = "skipped" \]' || true)"

    assert_not_empty "$skip_branch" \
        "A 'skipped' branch exists in the gate logic"
    assert_contains "$skip_branch" 'IS_FORK_PR' \
        "The skipped branch is CONDITIONAL on IS_FORK_PR — a non-fork skip is refused"
}

# The refusal path must actually fail. A branch that reports an error and then
# falls through to a success exit is the silent-pass shape again.
test_unacceptable_result_fails_closed() {
    local block
    block="$(merge_gate_block)"

    assert_contains "$block" 'rc=1' \
        "An unacceptable result sets rc=1 rather than only logging"
    assert_contains "$block" 'if [ "$rc" -ne 0 ]; then' \
        "The collected verdict is tested before the step can succeed"
}

# The ordering property #947 introduced, and the one most likely to regress: both
# fork-skippable gates must be evaluated before ANY exit. The pre-#947 shape
# exited 0 the moment quality-gates was green, which would have left the new BSD
# check unreachable on every passing run — the promotion looking done while
# gating nothing.
#
# Pinned by asserting the helper is invoked for BOTH jobs, and that no bare
# `exit 0` precedes them.
test_both_gates_are_checked_before_any_exit() {
    local block calls early_exit
    block="$(merge_gate_block)"

    calls="$(printf '%s\n' "$block" |
        command grep -cE '^[[:space:]]*check_gate[[:space:]]' || true)"
    assert_equals "2" "$calls" \
        "check_gate is invoked exactly twice — once per fork-skippable gate"

    assert_contains "$block" 'check_gate "quality-gates"' \
        "quality-gates is evaluated through the shared helper"
    assert_contains "$block" 'check_gate "bsd-probe"' \
        "bsd-probe is evaluated through the shared helper"

    # No `exit 0` may appear before the checks — that is exactly the
    # short-circuit this case exists to prevent. (The manifests guard above them
    # exits 1, never 0, so it is not caught by this.)
    early_exit="$(printf '%s\n' "$block" |
        command awk '/^[[:space:]]*check_gate[[:space:]]/ { exit } /exit 0/ { print }')"
    assert_equals "" "$early_exit" \
        "No 'exit 0' short-circuits the gate before both checks have run"
}

run_test test_anchor_is_not_vacuous "merge-gate anchor resolves (vacuity guard)"
run_test test_bsd_probe_is_in_needs "bsd-probe is in merge-gate's needs:"
run_test test_bsd_result_is_bound_from_needs "BSD_RESULT is bound from needs.bsd-probe.result"
run_test test_skip_is_tolerated_only_on_a_fork_pr "A skip is tolerated only on a fork PR"
run_test test_unacceptable_result_fails_closed "An unacceptable result fails closed"
run_test test_both_gates_are_checked_before_any_exit "Both gates are checked before any exit"

generate_report
