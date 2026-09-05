# shellcheck shell=bash
# Category: ai-slop
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Category: ai-slop ------------------------------------------------------

# A hedging phrase in a .py source must produce an ai-slop row. .py is chosen
# because test-skip-patterns scoping is irrelevant to ai-slop (it skips only
# data/doc extensions) and .py is unambiguously a scanned source type.
test_ai_slop_fires() {
    local d rows row
    d="$(fresh_dir)"
    command printf '%s\n' "# It's worth noting that this is unedited output." >"$d/slop.py"
    run_gate "$(make_list "$d" slop.py)"

    assert_exit 0 "$GATE_RC" "gate exits 0 while emitting findings"
    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_empty "$rows" "ai-slop fixture must emit an ai-slop row"

    # First ai-slop row: 5 columns, file is slop.py, certainty HIGH.
    row="$(command printf '%s\n' "$rows" | command head -1)"
    assert_equals "5" "$(command printf '%s\n' "$row" | command awk -F '\t' '{print NF}')" \
        "ai-slop row must have 5 tab-separated columns"
    assert_contains "$(field "$row" 1)" "slop.py" "column 1 is the fixture path"
    assert_equals "HIGH" "$(field "$row" 5)" "hedging phrase is HIGH certainty"
}

# #684: the alternatives a trailing `\b` had made unreachable.
#
# The fixture above uses "It's worth noting that", which ends in a word character
# and so matched all along — it passes with and without the fix. These are the
# ones that did not:
#
#   - Five of the eight hedging phrases end in a COMMA. `\b` after a non-word
#     character asserts the NEXT character is a word character, so
#     `Importantly, the …` (comma then SPACE) never matched. Only the
#     ungrammatical `Importantly,the` would have.
#   - `seamlessly integrat` is a STEM, meant to catch integrates/integrated/
#     integrating. The trailing `\b` demanded a non-word character right after
#     `t`, killing every inflection the stem exists for.
#
# One phrase per fixture, so a single surviving alternative cannot mask the rest.
test_ai_slop_comma_and_stem_alternatives_fire() {
    local d rows phrase i=0
    for phrase in \
        "Importantly, this handles the edge case." \
        "Notably, the parser is recursive." \
        "In essence, it is a lookup table." \
        "At its core, the design is a queue." \
        "Fundamentally, this is a cache."; do
        i=$((i + 1))
        d="$(fresh_dir)"
        command printf '# %s\n' "$phrase" >"$d/slop.py"
        run_gate "$(make_list "$d" slop.py)"

        rows="$(category_rows "$GATE_OUT" "ai-slop")"
        assert_not_empty "$rows" \
            "comma-terminated hedging phrase #${i} fires: ${phrase} (#684)"
    done

    # The `integrat` stem, across the inflections it was written for.
    for phrase in \
        "It seamlessly integrates with the queue." \
        "The module seamlessly integrated with the queue." \
        "We are seamlessly integrating the queue."; do
        d="$(fresh_dir)"
        command printf '# %s\n' "$phrase" >"$d/slop.py"
        run_gate "$(make_list "$d" slop.py)"

        rows="$(category_rows "$GATE_OUT" "ai-slop")"
        assert_not_empty "$rows" \
            "buzzword stem fires on an inflection: ${phrase} (#684)"
    done
}

# Negative half of the pair: dropping the trailing boundary must not make the
# leading one moot. A hedging phrase embedded INSIDE a longer word still must not
# fire — that is what the surviving leading `\b` is for. Without this, the fix
# could have been "delete both boundaries" and nothing would have objected.
test_ai_slop_leading_boundary_still_guards() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "# unnotably, and disimportantly, are not real words" >"$d/ok.py"
    run_gate "$(make_list "$d" ok.py)"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_contains "$rows" "ok.py" \
        "a hedging phrase inside a longer word does NOT fire — leading \\b still guards (#684)"
}
