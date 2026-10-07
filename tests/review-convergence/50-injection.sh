# shellcheck shell=bash
# Injection — untrusted finding text cannot forge a stop — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- Injection: untrusted finding text cannot forge a convergence stop ------
# Finding text originates from an LLM reviewer describing a diff, so `.file` and
# `.category` are untrusted and may carry content influenced by prompt injection
# in that diff. `jq -r` decodes JSON escapes, so an embedded `\n` would become a
# real newline and inject an extra record into the line-oriented `grep -F -x`
# layer — forging a C6 duplicate or C7 delta match, BOTH of which STOP the loop.
# The payoff of the attack is ending a review early, so these are convergence
# tests, not just parsing tests: each asserts the loop keeps going.

test_newline_in_file_cannot_forge_a_duplicate() {
    # The forged fingerprint goes FIRST, with the newline after it, so the real
    # `:line_start:category` suffix lands harmlessly on the second emitted line
    # and the first line is a byte-exact match for novel.json's fingerprint.
    # (Putting the newline before the payload does not work — the suffix would be
    # appended to the forged line and `grep -x` would miss. The distinction
    # matters: a fixture crafted the wrong way round passes with AND without the
    # sanitization, which is exactly the tautology class #599/#600 names.)
    # If the newline survives into $cur, this one finding emits two records, the
    # forged one matches $seen, duplicate reaches total, and C6 stops the loop.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/a.js:10:correctness\\nsrc/evil.js","line_start":99,"category":"x","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-dup.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-dup.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline-injected fingerprint must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    # `duplicate`, NOT `findings`: the findings counter is `jq length` over the
    # input array, so it reads 1 with and without the sanitization — asserting it
    # would be the very tautology this file's header warns about. `duplicate` is
    # what the injected record actually moves.
    assert_equals "0" "$(val duplicate "$out")" "the injected record does not register as a duplicate"
}

test_newline_in_file_cannot_forge_a_recursive_match() {
    # Same trick against C7: the injected second line is a path present in the
    # fix delta. Without sanitization the crafted record matches delta-files and
    # the loop stops as recursive-test-machinery.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/evil.js\\ntests/foo_test.sh","line_start":7,"category":"tests","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-rec.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-rec.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline-injected path must not forge a C7 stop"
    assert_equals "0" "$(val recursive "$out")" "the injected test path is not counted as recursive"
}

test_carriage_return_in_file_cannot_forge_a_recursive_match() {
    # Both filters treat CR as a record separator alongside LF, but every other
    # injection case here uses `\n` only — so the CR half was pinned by nothing.
    # Verified by mutation: narrowing `flat` to `gsub("\n";" ")` and dropping the
    # `%0D` encoding left the whole suite green.
    #
    # CR is forgeable on a different mechanism than LF. It does not split a line
    # for `grep`, so it cannot inject a second record; instead `flat` COLLAPSES it
    # to a space, which is what lets a crafted `.file` match a delta path that
    # genuinely contains a space. Drop the CR from `flat` and the byte stays
    # literal, so this fixture stops matching — which is why the assertion is a
    # C7 stop rather than the C8 continue the newline cases assert.
    command printf 'tests/foo test.sh\nsrc/fix.js\n' >"$FIXTURES/delta-space.txt"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"tests/foo\\rtest.sh","line_start":5,"category":"tests","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-cr.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-cr.json" \
        --delta-files "$FIXTURES/delta-space.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C7-recursive" "$(val rule "$out")" "a CR is normalized to a space like a newline is"
    assert_equals "1" "$(val recursive "$out")" "CR handling in flat is load-bearing, not vestigial"
}

test_newline_in_category_cannot_forge_a_duplicate() {
    # `.category` is interpolated into the same fingerprint and is equally
    # attacker-shaped; sanitizing only `.file` would leave this path open.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/evil.js","line_start":99,"category":"x\\nsrc/a.js:10:correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-cat.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-cat.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline in .category must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel"
}

test_colon_in_file_cannot_forge_a_duplicate() {
    # The delimiter vector, distinct from the newline one: no newline is involved.
    # These two findings are structurally DIFFERENT (different file, line, and
    # category) yet colon-join to the same string when the delimiter is not
    # neutralized:
    #     A: file="src/a.js:10" line=0  cat="correctness"   -> src/a.js:10:0:correctness
    #     B: file="src/a.js"    line=10 cat="0:correctness" -> src/a.js:10:0:correctness
    # So B looks like a repeat of A, C6 fires, and the loop stops on a cycle that
    # actually surfaced new material. Note the fixture must be a genuine COLLIDING
    # PAIR — an arbitrary colon-bearing path does not collide with anything and
    # would pass with and without the fix (verified by mutation).
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/a.js:10","line_start":0,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/colon-a.json"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/a.js","line_start":10,"category":"0:correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/colon-b.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/colon-b.json" \
        --prev-result "$FIXTURES/colon-a.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a colon-crafted collision must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "the colliding fingerprints stay distinct"
}

test_colon_in_path_still_matches_for_recursive() {
    # The complement, and why there are TWO filters: the C7 check matches a whole
    # path line, where `:` is not a delimiter. Substituting it there would break a
    # legitimate colon-bearing path — a MISSED recursive signal. `flat` (records
    # only) must apply there, `field` (records + colons) only to the fingerprint.
    command printf 'tests/we:ird_test.sh\nsrc/fix.js\n' >"$FIXTURES/delta-colon.txt"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"tests/we:ird_test.sh","line_start":5,"category":"tests","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/recursive-colon.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive-colon.json" \
        --delta-files "$FIXTURES/delta-colon.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C7-recursive" "$(val rule "$out")" "a colon-bearing test path still matches the fix delta"
    assert_equals "1" "$(val recursive "$out")" "colon substitution must not break real path matching"
}

test_underscore_and_colon_paths_do_not_collide() {
    # #618: the ACCIDENTAL half of the collision class, distinct from the crafted
    # collision above. These two findings differ only in one character of `.file`
    # and are structurally different, yet the old `gsub(":";"_")` sanitizer — a
    # many-to-one map — sent both to the SAME fingerprint:
    #     A: file="a:b"  line=10 cat="correctness" -> a_b:10:correctness
    #     B: file="a_b"  line=10 cat="correctness" -> a_b:10:correctness
    # So B reads as a repeat of A, C6 fires, and the loop stops on a cycle that
    # surfaced new material. Underscores are far more common in real paths than
    # colons, so this needs no attacker at all. The fix is an INJECTIVE encoding;
    # this pins that the pair stays distinct.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"a:b","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-colon.json"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"a_b","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-underscore.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/collide-underscore.json" \
        --prev-result "$FIXTURES/collide-colon.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a:b and a_b must not collide into a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "distinct inputs keep distinct fingerprints"
}

test_percent_in_path_does_not_collide_with_an_encoded_colon() {
    # The escape alphabet must itself be injective, or the fix just relocates the
    # collision. With `%` encoded FIRST, a literal `a%3Ab` becomes `a%253Ab` while
    # `a:b` becomes `a%3Ab` — distinct. Encode `:` first and BOTH become `a%3Ab`,
    # re-forging the C6 match through the encoding that was meant to prevent it.
    # This case is what makes the substitution ORDER load-bearing rather than
    # incidental; it fails against an otherwise-correct percent-encoder.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"a%%3Ab","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-percent.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/collide-percent.json" \
        --prev-result "$FIXTURES/collide-colon.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a literal %3A must not collide with an encoded colon"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "the escape alphabet is itself injective"
}

test_boolean_false_field_does_not_collide_with_an_absent_one() {
    # The last hole in the injectivity argument. `// ""` — the idiom both filters
    # used — fires on `false` as well as `null`, so a boolean-`false` `.category`
    # coerced to `""`, exactly like an absent one: two structurally different
    # findings, one fingerprint, a forged C6 stop. Same defect class as the `a:b`
    # / `a_b` collision, reached through a value TYPE rather than a character.
    # The explicit `. == null` test stringifies `false` to "false" instead.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/q.js","line_start":3,"category":false,"disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/false-cat.json"
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/q.js","line_start":3,"disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/absent-cat.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/false-cat.json" \
        --prev-result "$FIXTURES/absent-cat.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a false field must not collide with an absent one"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "only null defaults to the empty string"
}

test_sanitization_preserves_ordinary_matching() {
    # The complement: sanitizing must not break real duplicate detection. Without
    # this, a mutation that emptied every fingerprint would pass the three
    # injection tests above by making nothing ever match.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "ordinary fingerprints still match after sanitization"
}
