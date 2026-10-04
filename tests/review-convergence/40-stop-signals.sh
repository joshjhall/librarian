# shellcheck shell=bash
# C5 refuted-only, C6 duplicate, C7 recursive stop signals — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- C5: refuted-only -------------------------------------------------------

test_refuted_only_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle whose findings all failed verification is converged (#555)"
    assert_equals "C5-refuted-only" "$(val rule "$out")" "the refuted-only rule decides"
    assert_equals "2" "$(val refuted "$out")" "both refuted findings are counted"
}

test_partially_refuted_continues() {
    # C5 is ALL, not ANY. One live finding alongside a refuted one is still
    # material — this is the assertion that keeps C5 from swallowing real defects.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "one refuted finding among live ones is not convergence"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material outlives the refuted one"
}

# --- C6: duplicate findings -------------------------------------------------

test_all_duplicate_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle restating an earlier finding is converged (#533 cycle 5)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "the duplicate rule decides"
    assert_equals "0" "$(val novel "$out")" "nothing novel remains"
}

test_novel_finding_against_prior_continues() {
    # Same shape as the duplicate case but a DIFFERENT fingerprint — the pair
    # proves duplication is matched on the finding, not merely on "a prior result
    # file was supplied".
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/second.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a finding absent from the prior cycle is novel"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material continues"
    assert_equals "1" "$(val novel "$out")" "the new finding counts as novel"
    assert_equals "0" "$(val duplicate "$out")" "and not as a duplicate"
}

test_partially_duplicate_continues() {
    # C6 is ALL, not ANY — the same discipline C5 and C7 get, and the one this
    # suite originally missed. A cycle that restates one earlier finding AND
    # surfaces a new one is still producing material; stopping there would
    # discard the new defect on the very cycle it appeared.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-duplicate.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "one duplicate among novel findings is not convergence"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material outlives the duplicate"
    assert_equals "1" "$(val duplicate "$out")" "the repeat is counted as a duplicate"
    assert_equals "1" "$(val novel "$out")" "and the new finding as novel"
}

test_duplicate_matches_across_all_earlier_cycles() {
    # --prev-result is repeatable: a finding that reappears after skipping a
    # cycle is still a duplicate. Matching only the immediately-preceding cycle
    # would call this novel and loop.
    local out
    out="$("$RC" check --cycle 3 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" --prev-result "$FIXTURES/second.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "a finding from cycle 1 is a duplicate in cycle 3"
}

# --- C7: recursive test machinery ------------------------------------------

test_recursive_test_machinery_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "findings about the last fix's own test machinery are converged (#498)"
    assert_equals "C7-recursive" "$(val rule "$out")" "the recursive rule decides"
}

test_test_file_outside_the_fix_delta_is_not_recursive() {
    # The differential for C7: the SAME finding in the SAME test file, but that
    # file is not in the previous fix's delta. It is then ordinary material, not
    # the no-fixed-point class — proving C7 keys off delta membership rather than
    # just a test-looking path.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/delta-files-nontest.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a test file the last fix did not touch is real material"
    assert_equals "C8-novel" "$(val rule "$out")" "not the recursive rule"
    assert_equals "0" "$(val recursive "$out")" "and not counted as recursive"
}

test_mixed_recursive_continues() {
    # C7 is ALL, not ANY — a source defect alongside the test-machinery finding
    # keeps the loop alive.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-recursive.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a live source defect outlives a recursive test finding"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material decides"
}
