# shellcheck shell=bash
# C3 vs C4 — the narrow-delta-zero surface pair — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- C3 vs C4: the narrow-delta-zero pair (AC#2) ----------------------------
# THE differential. Both halves pass the SAME result file (zero.json), the same
# cycle, the same cap, the same prev-delta-lines. The ONLY difference is
# --delta-lines. A predicate that ignores surface comparability cannot pass both.

test_narrow_delta_zero_does_not_stop() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "AC#2: a zero on a 10%-of-previous surface must NOT terminate"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "the narrow-surface rule decides (#568 cycle 2)"
}

test_comparable_delta_zero_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a zero on a comparable surface IS convergence"
    assert_equals "C4-zero" "$(val rule "$out")" "the comparable-surface rule decides"
}

test_narrow_and_comparable_zero_differ_only_in_surface() {
    # Guards the pair itself against drift: if a future edit made these two
    # invocations differ in anything but --delta-lines, the differential above
    # would silently stop testing the surface comparison. Assert the two verdicts
    # are OPPOSITE from otherwise-identical inputs.
    local narrow comparable
    narrow="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --prev-delta-lines 400 --partial false)"
    comparable="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_true "[ \"$(val verdict "$narrow")\" != \"$(val verdict "$comparable")\" ]" \
        "the same zero-finding cycle yields opposite verdicts on narrow vs comparable surface"
}

test_zero_at_boundary_ratio_stops() {
    # Exactly at the 50% default ratio the surface is comparable (>= ratio), so a
    # zero stops. One line under it is narrow. Pins the boundary direction —
    # an off-by-one here silently converts every borderline cycle.
    local at under
    at="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 200 --prev-delta-lines 400 --partial false)"
    under="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 199 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$at")" "delta == 50% of previous is comparable -> stop"
    assert_equals "C3-narrow-zero" "$(val rule "$under")" "one line under the ratio is narrow -> continue"
}

test_cycle_one_zero_stops() {
    # #564: clean at cycle 1 on a move-only refactor. There is no predecessor, so
    # the surface is the whole diff — maximal, and a zero is real convergence.
    # Under the old counter this burned two more cycles.
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle-1 zero on the full diff terminates immediately (#564)"
    assert_equals "C4-zero" "$(val rule "$out")" "no predecessor -> the surface is comparable by construction"
}

test_surface_ratio_env_override_moves_the_boundary() {
    # Same 40-vs-400 inputs as the AC#2 case; a 10% ratio makes that surface
    # comparable and flips the verdict.
    local out
    out="$(REVIEW_CONVERGENCE_SURFACE_RATIO=10 "$RC" check --cycle 2 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 40 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "RATIO=10 makes a 10% surface comparable"
    assert_equals "C4-zero" "$(val rule "$out")" "the override moves the C3/C4 boundary"
}
