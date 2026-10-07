# shellcheck shell=bash
# Integration — the loop always terminates — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- Integration: the loop always terminates --------------------------------

test_loop_terminates_on_a_never_converging_review() {
    # The honest form of AC#3. A pathological review that returns novel findings
    # forever must still terminate — driven by the oracle, at the cap, in bounded
    # time. The safety bound (20 iterations) is far above the cap so a runaway is
    # caught by the assertion rather than by hanging the suite.
    local cycle=1 verdict="" out iterations=0
    while [ "$iterations" -lt 20 ]; do
        iterations=$((iterations + 1))
        out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle "$cycle" --max-cycles 5 --result "$FIXTURES/novel.json" \
            --delta-lines 400 --prev-delta-lines 400 --partial false)"
        verdict="$(val verdict "$out")"
        [ "$verdict" = "stop" ] && break
        cycle=$((cycle + 1))
    done
    assert_equals "stop" "$verdict" "a never-converging review is driven to stop"
    assert_equals "5" "$cycle" "it stops exactly at the cap, not before and not after"
}

test_loop_terminates_early_on_a_converged_review() {
    # The other half of the issue: the same loop, against a review that converges,
    # stops well before the cap. Without this the cap test alone would pass on
    # code that ignored every convergence signal.
    local cycle=1 verdict="" out iterations=0
    while [ "$iterations" -lt 20 ]; do
        iterations=$((iterations + 1))
        out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle "$cycle" --max-cycles 5 --result "$FIXTURES/zero.json" \
            --delta-lines 400 --prev-delta-lines 400 --partial false)"
        verdict="$(val verdict "$out")"
        [ "$verdict" = "stop" ] && break
        cycle=$((cycle + 1))
    done
    assert_equals "stop" "$verdict" "a converged review stops"
    assert_equals "1" "$cycle" "it stops at cycle 1, saving the remaining 4 (#564)"
}
