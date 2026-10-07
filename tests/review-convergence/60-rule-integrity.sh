# shellcheck shell=bash
# Rule-list integrity — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- Rule-list integrity ----------------------------------------------------

test_every_rule_is_reachable() {
    # Totality + reachability: each of the eight rules must actually fire for
    # some input. A rule that can never fire is dead policy — and a rule list
    # with an unreachable branch usually means an earlier condition is too broad.
    local rules="" out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 400 --prev-delta-lines 400 --partial true)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 40 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" --prev-result "$FIXTURES/novel.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" --delta-files "$FIXTURES/delta-files.txt" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"

    assert_contains "$rules" "C1-cap" "C1 is reachable"
    assert_contains "$rules" "C2-partial" "C2 is reachable"
    assert_contains "$rules" "C3-narrow-zero" "C3 is reachable"
    assert_contains "$rules" "C4-zero" "C4 is reachable"
    assert_contains "$rules" "C5-refuted-only" "C5 is reachable"
    assert_contains "$rules" "C6-duplicate" "C6 is reachable"
    assert_contains "$rules" "C7-recursive" "C7 is reachable"
    assert_contains "$rules" "C8-novel" "C8 is reachable"
}

test_every_verdict_is_continue_or_stop() {
    # The caller branches on exactly two values; a third would fall through its
    # case and silently continue.
    local out v
    for args in \
        "--cycle 5 --max-cycles 5 --result $FIXTURES/novel.json --delta-lines 400 --partial false" \
        "--cycle 2 --max-cycles 5 --result $FIXTURES/zero.json --delta-lines 40 --prev-delta-lines 400 --partial false" \
        "--cycle 2 --max-cycles 5 --result $FIXTURES/novel.json --delta-lines 400 --partial false"; do
        # shellcheck disable=SC2086  # deliberate word-splitting of the arg string
        out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" $args)"
        v="$(val verdict "$out")"
        assert_true "[ \"$v\" = continue ] || [ \"$v\" = stop ]" "verdict is continue|stop, got '$v'"
    done
}

test_counts_are_reported_on_every_verdict() {
    # The counts are the audit trail for a stop; a rule that returned early
    # without them would leave a terminated review unexplainable.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)"
    assert_not_empty "$(val findings "$out")" "findings count reported on a C1 stop"
    assert_not_empty "$(val novel "$out")" "novel count reported on a C1 stop"
    assert_not_empty "$(val duplicate "$out")" "duplicate count reported on a C1 stop"
    assert_not_empty "$(val refuted "$out")" "refuted count reported on a C1 stop"
    assert_not_empty "$(val recursive "$out")" "recursive count reported on a C1 stop"
}

test_deferrable_findings_count_as_material() {
    # Convergence is about whether reviewers still have MATERIAL. A deferrable
    # finding is material just as much as a blocking one — counting only
    # `blocking` would read the #580 all-deferrable cycles as converged, which is
    # the bucket that twice held a real defect.
    local out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[%s]}\n' \
        "$(finding "src/z.js" 60 correctness R7-large-effort)" >"$FIXTURES/deferrable-only.json"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/deferrable-only.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "1" "$(val findings "$out")" "a deferrable-only cycle has findings, not zero"
    assert_equals "C8-novel" "$(val rule "$out")" "and is therefore not a zero-convergence"
}
