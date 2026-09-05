# shellcheck shell=bash
# Category: debug-statement + scanner self-scan suppression (#599)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Category: debug-statement ----------------------------------------------

# A top-level console.log in a .js source must produce a debug-statement row.
test_debug_statement_fires() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "console.log('left in by accident');" >"$d/debug.js"
    run_gate "$(make_list "$d" debug.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_empty "$rows" "console.log fixture must emit a debug-statement row"
    assert_contains "$rows" "debug.js" "debug-statement row names the fixture"
}

# --- Scanner self-scan suppression (#599) -----------------------------------

# The detectors' patterns are regex literals inside their own grep/re.search
# calls, so scanning a diff that touches a scanner file made every literal match
# ITSELF — HIGH-certainty rows for a guaranteed non-problem, on exactly the PRs
# where reviewer attention is worth most.
#
# The fix is LINE-scoped, and this case pins BOTH halves of that from a SINGLE
# fixture, which is the whole point: the suppressed pattern-source line and a
# genuine hedging comment live in the same file. A path-based exemption (the
# rejected option 2) would silence both and still pass a test that only checked
# the first half — so asserting the negative alone would be a green light on the
# wrong implementation.
test_ai_slop_skips_scanner_pattern_literals() {
    local d rows
    d="$(fresh_dir)"
    {
        command printf '%s\n' "#!/usr/bin/env bash"
        command printf '%s\n' "# It's worth noting that this parser is fragile."
        command printf '%s\n' "scan() {"
        command printf '%s\n' "    command grep -niE -- '\\b(it.s worth noting that|importantly,)\\b' \"\$1\""
        command printf '%s\n' "}"
    } >"$d/scanner.sh"
    run_gate "$(make_list "$d" scanner.sh)"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    # The grep-invocation line (4) is pattern SOURCE — must not be flagged.
    assert_not_contains "$rows" "	4	" \
        "a scanner pattern-literal invocation emits no ai-slop row (#599 AC#1)"
    # ...while the prose comment (2) in the SAME file still fires. This is the
    # anti-blanket-exemption assertion (#599 AC#2).
    assert_contains "$rows" "	2	" \
        "a genuine hedging comment in a scanner file still fires (#599 AC#2)"
}

# The INVERSE of the ai-slop case above, and the #604 fix.
#
# #599 gave the debug arms the same is_scanner_pattern_line guard as ai-slop.
# That was wrong, and this case is the one that changed sides. The debug
# patterns are `^\s*`-anchored (`^\s*console\.`, `^\s*print\(`), so a scanner's
# own literal — always nested inside a grep call indented in a function — can
# never match line-start. The guard suppressed nothing real (measured: 0 rows
# across all three scanners) while dropping the only lines it COULD reach:
# genuine line-start debug statements whose ARGUMENT happens to look like a
# regex. Those are false negatives in ordinary source, invisible by
# construction.
#
# So both lines below must now FIRE. Line 1 is the exact shape #604 reported —
# a real `console.log` left behind whose argument merely contains
# regex-shaped text. Under the pre-#604 scanner it emitted nothing.
test_debug_statement_fires_on_regex_shaped_argument() {
    local d rows
    d="$(fresh_dir)"
    {
        # The `\s` below is fixture DATA, not a shell pattern: it is the JS source
        # line written to scan.js, whose argument must contain regex-shaped text
        # for the #604 assertion to mean anything. Rewriting it destroys the case.
        command printf '%s\n' "console.log(\"grep -nE -- '^\\\\s*console\\\\.(log)\\\\('\");" # lint-allow-gnu-regex: JS fixture payload (#604)
        command printf '%s\n' "console.log('genuine debug left behind');"
    } >"$d/scan.js"
    run_gate "$(make_list "$d" scan.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "	1	" \
        "a debug statement whose argument contains regex-shaped text still fires (#604 AC#1)"
    assert_contains "$rows" "	2	" \
        "a genuine console.log in the same file still fires (#604)"
}

# The other half of #604's AC#1, in the language the issue reported it in: the
# python arm, whose argument carries an `re.search(r"..."` literal. A separate
# fixture because the two arms are separate `case` branches — a js-only fixture
# asserts nothing about the py arm.
test_debug_statement_fires_on_python_regex_argument() {
    local d rows
    d="$(fresh_dir)"
    {
        command printf '%s\n' 'print(re.search(r"\d+", data))'
        command printf '%s\n' 'print("a genuine debug print")'
    } >"$d/app.py"
    run_gate "$(make_list "$d" app.py)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "	1	" \
        "a print() whose argument contains re.search(r\"...\") still fires (#604 AC#1)"
    assert_contains "$rows" "	2	" \
        "a plain debug print in the same file still fires (#604)"
}

# WHY the removed guard was unnecessary, pinned as behavior rather than prose.
#
# A scanner's own pattern literal is indented inside a function, so the `^\s*`
# anchor is what prevents the self-match — not the deleted predicate. This case
# fails if someone ever unanchors a debug pattern (which would reintroduce the
# #599 self-match the guard existed for) and documents why re-adding the guard
# is not the remedy: anchor the new pattern instead.
#
# The fixture's line 2 must hold the literal text `console.log(` — a real dot
# and a real paren. The obvious-looking fixture (a `grep -nE -- '^\s*console\.'`
# invocation) does NOT work: its `\.` and `\(` are backslash-escaped ON DISK, so
# the detector's own `console\.` / `\(` never match them, and the case then
# passes with the pattern anchored OR unanchored — a tautology that pins
# nothing. Verified: mutating the arm to drop its `^\s*` makes line 2 fire here.
test_indented_scanner_pattern_literal_does_not_self_match() {
    local d rows
    d="$(fresh_dir)"
    {
        command printf '%s\n' "scan() {"
        command printf '%s\n' "    const DEBUG_RE = \"console.log(\";"
        command printf '%s\n' "}"
        command printf '%s\n' "console.log('genuine debug left behind');"
    } >"$d/scanner.js"
    run_gate "$(make_list "$d" scanner.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    # Line 2 carries the detector's own literal, but INDENTED — the anchor
    # rejects it with no guard in play.
    assert_not_contains "$rows" "	2	" \
        "an indented scanner pattern literal self-matches no debug arm (#604: anchoring, not the guard)"
    # ...and the scanner going silent cannot be why: line 4 still fires.
    assert_contains "$rows" "	4	" \
        "...while a real console.log in the same file still fires (#604)"
}

# ai-slop never called is_test_file, unlike debug-statement which always has
# (#599). A corpus fixture GENERATES slop on purpose — the heredoc and `printf`
# lines that build a detector's input are not unedited AI output. Measured over
# the #567 batch these fixture-generator lines were the majority of surviving
# ai-slop rows.
test_ai_slop_skips_test_files() {
    local d rows control
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' "# It's worth noting that this fixture is deliberate." >"$d/tests/fixture.py"
    command printf '%s\n' "# It's worth noting that this is unedited output." >"$d/src.py"
    run_gate "$(make_list "$d" tests/fixture.py src.py)"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_contains "$rows" "fixture.py" \
        "a hedging phrase under tests/ emits no ai-slop row (#599)"
    # Control: the same phrase in real source still fires, so the suppression is
    # scoped to test paths rather than having disabled the detector outright.
    control="$(command printf '%s\n' "$rows" | command grep -c 'src\.py' || true)"
    assert_equals "1" "$control" \
        "...while the same phrase in a non-test source still fires (#599)"
}
