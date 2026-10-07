# shellcheck shell=bash
# C1 cap, C2 partial, C2b unengaged — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- C1: the hard cap always terminates (AC#3) ------------------------------

test_cap_stops_even_with_novel_findings() {
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "cycle == max-cycles -> stop"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap is the deciding rule, not a convergence signal"
}

test_cap_outranks_partial() {
    # C2 would say `continue` forever on a run that keeps truncating. The cap
    # must outrank it or termination is not guaranteed — this is the assertion
    # that makes AC#3 hold in the presence of the C2 safety rule.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --partial true)"
    assert_equals "stop" "$(val verdict "$out")" "the cap stops a partial cycle too"
    assert_equals "C1-cap" "$(val rule "$out")" "C1 outranks C2 (termination is guaranteed)"
}

test_below_cap_does_not_stop_on_the_counter() {
    # The complement of the cap test, and the core of the issue: at cycle 4 of 5
    # — past the OLD default of 3 — novel material keeps the loop running.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 4 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "cycle 4 with novel findings continues (#533 shipped a defect here)"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material is the deciding rule"
}

# --- C2: a partial cycle is never a convergence stop ------------------------

test_partial_zero_does_not_converge() {
    # Identical to the C4 stop case except --partial. A budget-exhausted cycle's
    # zero describes the dimensions that RAN, not the review.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial true)"
    assert_equals "continue" "$(val verdict "$out")" "a partial zero-finding cycle must not terminate the loop"
    assert_equals "C2-partial" "$(val rule "$out")" "C2 outranks the zero rules"
}

test_partial_refuted_does_not_converge() {
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial true)"
    assert_equals "continue" "$(val verdict "$out")" "a partial refuted-only cycle must not terminate the loop"
    assert_equals "C2-partial" "$(val rule "$out")" "C2 outranks C5"
}

# --- C2b: an unengaged dimension is never a convergence stop (#1111) --------
# Each case is the C4 stop case (zero.json-shaped, comparable surface,
# --partial false) with ONE difference: the result names an unengaged
# dimension. --partial is deliberately false — C2b must fire from the result
# itself, because the caller that forgets --partial is the one that shipped the
# empty-security PRs.

test_unengaged_zero_does_not_converge() {
    local f="$FIXTURES/unengaged.json" out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[],"clean":false,"unengaged_dimensions":["security"]}\n' >"$f"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$f" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "#1111 AC2: a zero with an unengaged dimension must NOT terminate"
    assert_equals "C2b-unengaged" "$(val rule "$out")" "C2b decides, not C4-zero"
    assert_equals "1" "$(val unengaged "$out")" "the unengaged count is reported"
}

test_unengaged_outranks_refuted_only() {
    # C2b sits above C5-C7: "every finding was refuted" says nothing about the
    # dimension that produced none.
    local f="$FIXTURES/unengaged-refuted.json" out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[%s],"unengaged_dimensions":["tests"]}\n' \
        "$(finding "src/c.js" 30 correctness R2-low-certainty)" >"$f"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$f" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C2b-unengaged" "$(val rule "$out")" "C2b outranks C5-refuted-only"
}

test_unengaged_is_charged_to_the_cap() {
    # Charged, unlike C0b: a dimension that disengages every cycle dead-ends at
    # C1 and reports what the cap concealed.
    local f="$FIXTURES/unengaged-cap.json" out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[],"unengaged_dimensions":["security"]}\n' >"$f"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$f" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C1-cap" "$(val rule "$out")" "an unengaged cycle at the cap still stops on C1"
    assert_equals "C2b-unengaged" "$(val capped_over "$out")" "and capped_over names the unengaged rule"
}

test_unengaged_field_absent_or_malformed_reads_zero() {
    # Pre-#1111 results, and a field of the wrong type, keep their meaning.
    local empty="$FIXTURES/unengaged-empty.json" bad="$FIXTURES/unengaged-bad.json" out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[],"unengaged_dimensions":[]}\n' >"$empty"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[],"deferrable":[],"unengaged_dimensions":"security"}\n' >"$bad"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "an absent field still converges on C4"
    assert_equals "0" "$(val unengaged "$out")" "an absent field reports 0"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$empty" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "an empty list still converges on C4"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$bad" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "a non-array field reads as 0, not as a jq crash"
}
