# shellcheck shell=bash
# Capped_over — what C1 concealed (#635) — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- capped_over: what C1 concealed (#635) ----------------------------------
#
# ANTI-TAUTOLOGY: every case here asserts `capped_over` against a fixture whose
# UNCAPPED verdict is independently pinned by the paired assertion below it. A
# `capped_over` that merely echoed `rule`, or that hardcoded one value, fails the
# pair — the two halves differ only in `--max-cycles`.

test_capped_over_names_the_would_be_narrow_zero() {
    # The #635 reproduction, with the issue's own numbers: PR #634 cycle 5
    # returned zero over a 149-line delta against the previous cycle's 647 (23%,
    # under the 50% floor). The cap fired on a cycle the rule list itself calls
    # uninformative, and `verdict` alone could not say so.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 149 --prev-delta-lines 647 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "the cap still stops (C1 outranks C3)"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap is still the deciding rule"
    assert_equals "C3-narrow-zero" "$(val capped_over "$out")" \
        "capped_over names the rule the cap concealed (#635)"
}

test_capped_over_matches_the_verdict_with_the_cap_lifted() {
    # The differential half: the SAME inputs with the cap raised must actually
    # produce the rule `capped_over` claimed. This is what makes the assertion
    # above non-tautological — it pins capped_over against an independently
    # computed value rather than against a constant.
    local capped lifted
    capped="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 149 --prev-delta-lines 647 --partial false)"
    lifted="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 99 --result "$FIXTURES/zero.json" \
        --delta-lines 149 --prev-delta-lines 647 --partial false)"
    assert_equals "C3-narrow-zero" "$(val rule "$lifted")" "with the cap lifted, C3 decides"
    assert_equals "continue" "$(val verdict "$lifted")" "and it would have CONTINUED"
    assert_equals "$(val rule "$lifted")" "$(val capped_over "$capped")" \
        "capped_over equals the rule the uncapped run reports"
}

test_capped_over_distinguishes_a_corroborated_cap() {
    # The other side of the disambiguation, and the reason the field is worth
    # more than a boolean: a cap that coincides with a REAL convergence signal.
    # Same cycle and cap as the narrow-zero case — only the surface differs — so
    # a capped_over that ignored the inputs cannot report both.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap decides"
    assert_equals "C4-zero" "$(val capped_over "$out")" \
        "a comparable-surface zero at the cap is corroborated convergence"
}

test_capped_over_reports_still_productive_material() {
    # The worst case for a caller: the cap fired while reviewers still had novel
    # material (#533's only blocking finding arrived past the then-cap). The stop
    # is a pure budget artifact and capped_over must say so.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap decides"
    assert_equals "C8-novel" "$(val capped_over "$out")" \
        "capped_over reports that novel material remained"
}

test_capped_over_reports_a_capped_partial() {
    # C2 is the rule directly under C1, so this is the tightest ordering probe:
    # a partial cycle at the cap must report C1 as the rule and C2 as what it
    # concealed — proving the field walks the real chain rather than skipping to
    # the zero/finding rules.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --partial true)"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap outranks C2 (termination intact)"
    assert_equals "C2-partial" "$(val capped_over "$out")" "capped_over reports the partial"
}

test_capped_over_is_empty_on_a_non_cap_stop() {
    # A genuine C4-zero convergence: nothing was concealed, so the field must be
    # empty. Without this, a capped_over that always reported something would
    # make every stop look like a budget artifact.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "a real convergence stop"
    assert_equals "" "$(val capped_over "$out")" "capped_over is empty when C1 did not fire"
}

test_capped_over_is_emitted_on_every_verdict() {
    # The output contract: the KEY is always present (possibly empty), so a
    # caller can read it unconditionally without testing for its existence.
    local out
    for out in \
        "$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)" \
        "$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 400 --partial false)" \
        "$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" --delta-lines 400 --partial false)"; do
        assert_contains "$out" "capped_over=" "capped_over key present on every verdict"
    done
}
