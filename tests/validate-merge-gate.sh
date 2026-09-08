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

# count_exit_zero — read shell text on stdin, print how many `exit 0` STATEMENTS
# it contains. Used both by the gate assertion and by the detector's own
# regression test, so the two can never drift: a fixture that re-spelled the
# pattern would be testing a copy, not the thing that runs.
#
# `sed 's/#.*$//'` strips inline comments. It is a deliberate over-approximation
# — it also blanks a `#` inside a quoted string — and it cuts BOTH ways, so
# neither direction is left implied:
#   - It can HIDE a real `exit 0` that sits after a `#` inside a string. No
#     success path does that, and the strip is what makes `exit 0  # note`
#     detectable at all.
#   - It does NOT make the match string-aware, so `echo "x; exit 0"` WOULD be
#     flagged. That is a known, accepted false positive: this gate reads one
#     small hand-maintained YAML block, and over-reporting there is a visible
#     failure someone fixes, where under-reporting is the silent hole v1 and v2
#     both shipped.
count_exit_zero() {
    command sed 's/#.*$//' |
        command grep -cE '(^|[;&|)]|[[:space:]](then|else))[[:space:]]*exit[[:space:]]+0([[:space:]]|[;&|]|$)' || true
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
# Pinned by asserting the helper is invoked for BOTH jobs, and that the block
# contains NO `exit 0` at all.
#
# The zero-`exit 0` assertion is deliberately whole-block rather than positional,
# and it took three attempts to get right — worth recording, because each failure
# was the same mistake in a new place: the detector was narrower than the property
# its message claimed.
#
#   v1 scanned only as far as the opening `check_gate` line (awk's `exit` halts
#      the program), so it was blind to an `exit 0` inserted BETWEEN the two
#      calls — precisely the regression it named. Wrong on POSITION.
#   v2 scanned the whole block but anchored `^…$`, matching only a line that is
#      nothing but `exit 0`. `exit 0;`, `exit 0  # fast path`, `cond && exit 0`
#      and `if c; then exit 0; fi` all sailed through. Wrong on SHAPE — and the
#      v1 mutation test missed it because it happened to use the bare form.
#
# v3 (this one) strips inline comments, then matches `exit 0` as a STATEMENT
# anywhere on the line: at line start or after a `;`/`&&`/`||`/`)`/`then`/`else`,
# and terminated by a `;`, `&`, `|`, whitespace, or end of line. The `0` must be a
# whole token, so `exit 01` and `exit 0x` do not match. The `)` covers a
# case-statement arm (`*) exit 0 ;;`) — a sixth shape, found by review after v3
# closed the first five, which is the honest reason the boundary class is a class
# and not an enumeration.
#
# Whole-block is the right scope because a correct implementation has exactly one
# success path — falling off the end after the `rc` check — so every `exit 0` is a
# short-circuit by construction, wherever it sits, and no ordering logic is needed
# to say so. (The validate-manifests guard exits 1, not 0, so it is unaffected.)
#
# Every shape named above is pinned by test_exit_zero_detector_catches_all_shapes
# below, NOT merely by the prose here — three rounds of "verified by hand during
# development" is exactly what let v1 and v2 ship.
test_both_gates_are_checked_before_any_exit() {
    local block calls exit_zeroes
    block="$(merge_gate_block)"

    calls="$(printf '%s\n' "$block" |
        command grep -cE '^[[:space:]]*check_gate[[:space:]]' || true)"
    assert_equals "2" "$calls" \
        "check_gate is invoked exactly twice — once per fork-skippable gate"

    assert_contains "$block" 'check_gate "quality-gates"' \
        "quality-gates is evaluated through the shared helper"
    assert_contains "$block" 'check_gate "bsd-probe"' \
        "bsd-probe is evaluated through the shared helper"

    exit_zeroes="$(printf '%s\n' "$block" | count_exit_zero)"
    assert_equals "0" "$exit_zeroes" \
        "The gate has NO 'exit 0' in any shape (bare, ;-terminated, commented, &&-chained, case arm, or inline in a then/else) — its only success path is falling off the end after the rc check"
}

# The detector's OWN regression test, over synthetic input (#947 review cycle 3).
#
# Every previous version of count_exit_zero was "verified by hand during
# development" and shipped a hole anyway — twice. A comment claiming five shapes
# were checked is not a check; it cannot fail. So the shapes are enumerated here
# as data, and a future simplification of the pattern that narrows it back to v1
# or v2 behavior fails THIS case rather than being rediscovered by review.
#
# The negative arm matters just as much: a detector that flags `exit 01` or a
# mention inside a string would be reverted by whoever hits the false positive,
# taking the real coverage with it.
test_exit_zero_detector_catches_all_shapes() {
    local caught missed

    # Each line is a distinct way to spell a short-circuiting `exit 0`.
    caught="$(printf '%s\n' \
        'exit 0' \
        '  exit 0;' \
        '  exit 0  # fast path' \
        '  [ "$x" = y ] && exit 0' \
        '  false || exit 0' \
        '  if c; then exit 0; fi' \
        '  if c; then :; else exit 0; fi' \
        '  *) exit 0 ;;' | count_exit_zero)"
    assert_equals "8" "$caught" \
        "Every spelling of a short-circuiting 'exit 0' is detected (8 shapes)"

    # Things that merely LOOK like one. A false positive here would make the
    # gate unusable and get the detector weakened.
    missed="$(printf '%s\n' \
        '  exit 01' \
        '  exit 0x' \
        '  exit 1' \
        '  echo "exit 0 is banned"' \
        '  # exit 0' | count_exit_zero)"
    assert_equals "0" "$missed" \
        "Near-misses are NOT flagged: exit 01, exit 0x, exit 1, a mention in a string, a commented-out line"
}

run_test test_anchor_is_not_vacuous "merge-gate anchor resolves (vacuity guard)"
run_test test_bsd_probe_is_in_needs "bsd-probe is in merge-gate's needs:"
run_test test_bsd_result_is_bound_from_needs "BSD_RESULT is bound from needs.bsd-probe.result"
run_test test_skip_is_tolerated_only_on_a_fork_pr "A skip is tolerated only on a fork PR"
run_test test_unacceptable_result_fails_closed "An unacceptable result fails closed"
run_test test_both_gates_are_checked_before_any_exit "Both gates are checked before any exit"
run_test test_exit_zero_detector_catches_all_shapes "The exit-0 detector catches every shape (and no near-miss)"

generate_report
