# shellcheck shell=bash
# Evidence fidelity: trailing colons (#573)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Evidence fidelity: trailing colons (#573) -------------------------------
#
# `while IFS=: read -r line_num content` over `grep -n` output splits on EVERY
# colon and assigns the remainder to `content` — except that a trailing empty
# field is dropped, so content ending in a colon LOSES it.
#
# The fixture choice is the whole test. The strip only triggers when the content
# has EXACTLY ONE colon AND ends with it:
#
#   grep -n output          IFS=: content        correct content
#   5:# TODO fix:           # TODO fix           # TODO fix:      <- differs
#   6:a:b:c:                a:b:c:               a:b:c:           <- identical
#
# So an interior-colon probe passes with AND without the fix — it would look like
# a test while pinning nothing. test_interior_colons_survive_both_ways below
# makes that trap explicit rather than leaving it as tribal knowledge.

# The ai-slop family (4 of the 7 sites). The placeholder arm is used because its
# pattern (`# TODO: implement`) can be followed by content that ends in a colon.
test_ai_slop_evidence_keeps_trailing_colon() {
    local sb rows evidence
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    # The hedging phrase is the match; the trailing colon is the payload. The
    # line carries EXACTLY ONE colon (the final one) after grep strips its own
    # `N:` prefix — the only shape the defect actually damages.
    command printf '%s\n' \
        "value = 1" \
        "# It's worth noting that the remaining work is tracked here:" >"$sb/src/slop_colon.py"
    command printf '%s\n' "$sb/src/slop_colon.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_empty "$rows" "the hedging fixture emits an ai-slop row at all"
    evidence="$(field "$rows" 4)"
    assert_contains "$evidence" "tracked here:" \
        "ai-slop evidence retains the trailing colon (#573)"
}

# The untested-public-api family (the other 3 sites). The py arm is used; its
# evidence is the `def` line, so the trailing colon is intrinsic to the syntax —
# which is exactly why this family lost it on EVERY row before the fix, not just
# on unusual ones.
test_untested_api_evidence_keeps_trailing_colon() {
    local sb rows evidence
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        "def public_thing():" "    return 1" >"$sb/src/api_colon.py"
    command printf '%s\n' "$sb/src/api_colon.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_empty "$rows" "the py fixture emits an untested-public-api row at all"
    evidence="$(field "$rows" 4)"
    assert_contains "$evidence" "def public_thing():" \
        "untested-public-api evidence retains the def line's trailing colon (#573)"
    # And the line number is still parsed correctly — the new ${raw%%:*} split
    # must not have shifted it.
    assert_equals "1" "$(field "$rows" 2)" \
        "the line number is still the first field, not part of the content"
}

# Guard the fixture-choice trap directly: content with INTERIOR colons is
# unaffected by the defect, so a case built on it would pass pre-fix too. This
# asserts the survivable shape survives — if this ever fails, the split is
# over-eager in the other direction (eating content that never had a problem).
test_interior_colons_survive_both_ways() {
    local sb rows evidence
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    # `def a_b_c(x): return 1` — a one-line body puts a SECOND colon on the same
    # line, which is the survivable shape: IFS=: assigns everything after the
    # first colon to `content`, so an interior colon was never lost.
    command printf '%s\n' \
        "def ratio_parser(x): return 'a:b:c:'" >"$sb/src/interior.py"
    command printf '%s\n' "$sb/src/interior.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_empty "$rows" "the interior-colon fixture emits a row at all"
    evidence="$(field "$rows" 4)"
    assert_contains "$evidence" "a:b:c:" \
        "interior colons survive — this shape pinned nothing pre-fix (#573 fixture trap)"
}
