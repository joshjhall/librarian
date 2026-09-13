# shellcheck shell=bash
# REPORT SAFETY — a live label name must not be able to reshape the report.
#
# Sourced, not executed; see tests/validate-label-vocab-reconcile.sh.
#
# The declared side is repo content and trusted; the live side comes from
# `gh label list`, and label creation is a triage-level permission. The step
# summary renders as GFM, so these cases drive md_safe through the REAL script
# and assert that markdown, autolinks, control characters and (since #999) the
# multi-byte Unicode format characters are all neutralized — while ordinary
# non-ASCII still renders, which is the other half of the same property.

test_markdown_in_a_live_label_name_is_neutralized() {
    local box
    box="$(make_sandbox status/in-progress)"
    # A live label name carrying markdown. Label creation is a triage-level
    # permission and the step summary renders as GFM, so an unescaped name could
    # reshape the very report the job exists to have believed.
    stub_gh "$box" ok status/in-progress 'status/x[bad](http://e.invalid)'

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is still reported as drift"
    # The name is still identifiable (evidence survives) but is no longer markup.
    assert_contains "$RC_OUT" "status/x" "the label is still named in the report"
    assert_not_contains "$RC_OUT" "](http" "the link syntax is neutralized"
}

test_backtick_and_newline_in_a_label_name_are_neutralized() {
    local box line_count
    box="$(make_sandbox status/in-progress)"
    # The BACKTICK path, which md_safe's comment calls out by name ("escapes its
    # code span") but the bracket/paren case above never exercises — a different
    # GFM vector, and `tr` is byte-wise so it is a distinct code path.
    stub_gh "$box" ok status/in-progress 'status/x`code`y'

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is still reported as drift"
    assert_contains "$RC_OUT" "status/x" "the label is still named"
    # Each finding is emitted as `- \`name\``, so exactly two backticks belong on
    # that line. A name carrying its own would make four and break the span.
    line_count="$(command printf '%s\n' "$RC_OUT" | command grep -c 'status/x' || true)"
    assert_equals "1" "$line_count" "the neutralized name occupies exactly one line"
    assert_contains "$RC_OUT" "status/x?code?y" "the backticks are replaced, not deleted"
}

test_a_multiline_label_name_cannot_open_a_heading() {
    local box heading_count
    box="$(make_sandbox status/in-progress)"
    # A label name spanning two lines, the second of which is markdown block
    # syntax. Note WHICH mechanism stops this, because the first draft of this case
    # credited the wrong one: `gh label list` is LINE-BASED, so a multi-line name
    # arrives as two separate lines and the `^status/` filter drops the second
    # outright. Mutating md_safe's newline collapse away left this case still
    # passing — the filter, not the neutralizer, is the load-bearing part here.
    # Recorded rather than papered over: the assertion is kept for the property
    # (no injected heading reaches the report) with the real reason named, instead
    # of standing as false evidence for md_safe.
    stub_gh "$box" ok status/in-progress 'status/evil
### FAKE HEADING'

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "drift is still reported"
    heading_count="$(command printf '%s\n' "$RC_OUT" | command grep -c '^### FAKE' || true)"
    assert_equals "0" "$heading_count" "no label-injected heading reaches the report"
    assert_not_contains "$RC_OUT" "FAKE HEADING" "the second line is filtered out entirely"
}

test_md_safe_collapses_a_tab_in_a_live_label_name() {
    local box
    box="$(make_sandbox status/in-progress)"
    # md_safe's control-character collapse, driven through the REAL script rather
    # than a copy of the function. A first draft re-declared md_safe inside the
    # test, which tests the copy and would keep passing after the real one changed
    # — the wrong-copy-under-test shape. A TAB is the way in: unlike a newline it
    # survives gh's line-based output, so it actually reaches md_safe.
    stub_gh "$box" ok status/in-progress "$(command printf 'status/tab\there')"

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is reported as drift"
    assert_contains "$RC_OUT" "status/tab here" "the tab is collapsed to a space"
    assert_not_contains "$RC_OUT" "$(command printf 'status/tab\there')" \
        "the raw tab does not reach the report"
}

test_step_summary_mirrors_stdout() {
    local box summary
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress
    summary="$box/step-summary.md"
    : >"$summary"

    # emit() writes to stdout AND $GITHUB_STEP_SUMMARY. The summary is the only
    # place a scheduled job's findings are visible without digging into raw logs,
    # so a silently-broken append would make the job effectively invisible while
    # still exiting the right code. Never exercised until now.
    local rc=0
    /usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        GITHUB_STEP_SUMMARY="$summary" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "the drift case still exits 1"
    assert_file_contains "$summary" "status/blocked" \
        "the finding reaches the step summary, not only stdout"
    assert_file_contains "$summary" "Declared but absent" \
        "and so does the section that frames it"
}

test_all_md_safe_metacharacters_are_neutralized() {
    local box raw
    box="$(make_sandbox status/in-progress)"
    # md_safe maps THIRTEEN characters — ` [ ] ( ) * _ ~ # | < > : — and this one
    # label carries every one of them, so an off-by-one between the tr class and its
    # replacement string cannot hide in any of the thirteen.
    #
    # THE COUNT AND THE FIXTURE ARE BOTH LOAD-BEARING, and both were wrong once. The
    # comment said TWELVE (the `:` added later for autolinks was never counted) while
    # the fixture carried only seven, so a comment claiming whole-class coverage sat
    # over a partial one. The six stragglers happened to be covered by the backtick,
    # markdown-injection and autolink tests, which is what made the false claim
    # survive: incremental coverage elsewhere is not the same as the single-label
    # guarantee this test's own name promises. Widened rather than reworded, so the
    # claim is true instead of merely honest about being partial.
    raw='status/x`c`[b](u)*e*_m_~t~#h|p<l>g:z'
    stub_gh "$box" ok status/in-progress "$raw"

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is reported"
    # MEASURED from the real pipeline, never hand-written. Every mapped character
    # becomes `?`, closers included, so the pairs collapse to `??`. An earlier draft
    # guessed openers-only and failed; a guessed transformation is how a test ends up
    # pinning the wrong behavior on the day it happens to pass.
    assert_contains "$RC_OUT" "status/x?c??b??u??e??m??t??h?p?l?g?z" \
        "all thirteen mapped characters are replaced, in one label"
    assert_not_contains "$RC_OUT" "$raw" "the raw metacharacters never reach the report"
}

test_autolink_in_a_label_name_is_neutralized() {
    local box
    box="$(make_sandbox status/in-progress)"
    # GFM linkifies a BARE url with no bracket syntax, so neutralizing brackets and
    # parens alone still lets a label name plant a clickable link in the report.
    stub_gh "$box" ok status/in-progress 'status/see-https://evil.example/x'

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is reported"
    assert_not_contains "$RC_OUT" "https://" "the url scheme is broken"
    assert_contains "$RC_OUT" "status/see-https?//evil.example/x" \
        "the name stays legible as evidence, minus the scheme"
}

# --- multi-byte Unicode format characters (#999, following #816) -------------
# The cases above all drive SINGLE-BYTE ASCII, which is the only thing `tr` can
# express. These three drive what it structurally cannot.

test_bidi_override_in_a_label_name_is_neutralized() {
    local box rtlo raw
    box="$(make_sandbox status/in-progress)"
    # U+202E RIGHT-TO-LEFT OVERRIDE — the dangerous one. It does not merely style
    # text: everything after it RENDERS REVERSED, so a hostile label can display
    # as something other than what it is, in the very report this job exists to
    # have believed. `tr` is a BYTE tool and U+202E is three bytes (e2 80 ae), so
    # it passed through whole until #999 added the sed pass.
    #
    # Built with printf OCTAL ESCAPES, not pasted raw: stub_gh single-quotes the
    # name into the generated shim, and a fixture that is invisible in the source
    # is one nobody can review. Octal (not \xNN) for the same BSD-portability
    # reason the subject uses it.
    rtlo="$(command printf '\342\200\256')"
    raw="status/x${rtlo}evil"
    stub_gh "$box" ok status/in-progress "$raw"

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is still reported as drift"
    # MEASURED from the real pipeline, never hand-written — the same discipline
    # the thirteen-metacharacter case above records.
    assert_contains "$RC_OUT" "status/x?evil" \
        "the override is replaced, and the name stays legible as evidence"
    assert_not_contains "$RC_OUT" "$rtlo" \
        "no raw bidi override survives into the report"
}

test_zero_width_chars_in_a_label_name_are_neutralized() {
    local box zwsp bom raw
    box="$(make_sandbox status/in-progress)"
    # The rest of the family, which disguises a name rather than reversing it: a
    # zero-width space renders as NOTHING, so `status/a<ZWSP>b` and `status/ab`
    # are indistinguishable on screen while being different labels.
    #
    # EVERY ONE OF THE FIFTEEN ENUMERATED CODE POINTS, in one label, for exactly
    # the reason test_all_md_safe_metacharacters_are_neutralized covers all
    # thirteen `tr`-mapped ASCII characters in one: _MD_BIDI_BYTES is three
    # separately-typed chunks of octal escapes concatenated into one alternation,
    # and a sampled fixture cannot distinguish "the chunk is right" from "the one
    # byte I happened to pick is right". A first draft tested four (U+202E,
    # U+200B, U+2066, U+FEFF) and its comment claimed an off-by-one "cannot hide"
    # — but the untested members included each group's own BOUNDARY (U+200F,
    # U+202A, U+2069), which is precisely where a fencepost error lands. Widened
    # so the claim is true rather than merely plausible.
    #
    # Order matches the enumeration: zero-width U+200B-200F, embeddings/overrides
    # U+202A-202E, isolates U+2066-2069, BOM U+FEFF.
    zwsp="$(command printf '\342\200\213')"
    bom="$(command printf '\357\273\277')"
    raw="status/a${zwsp}b$(command printf '\342\200\214')c$(command printf '\342\200\215')"
    raw="${raw}d$(command printf '\342\200\216')e$(command printf '\342\200\217')"
    raw="${raw}f$(command printf '\342\200\252')g$(command printf '\342\200\253')"
    raw="${raw}h$(command printf '\342\200\254')i$(command printf '\342\200\255')"
    raw="${raw}j$(command printf '\342\200\256')k$(command printf '\342\201\246')"
    raw="${raw}l$(command printf '\342\201\247')m$(command printf '\342\201\250')"
    raw="${raw}n$(command printf '\342\201\251')o${bom}p"
    stub_gh "$box" ok status/in-progress "$raw"

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is still reported as drift"
    # MEASURED from the real pipeline, never hand-written. Fifteen separators, so
    # fifteen `?` between the sixteen ASCII letters — a missing member of any
    # chunk collapses its pair and this string stops matching.
    assert_contains "$RC_OUT" "status/a?b?c?d?e?f?g?h?i?j?k?l?m?n?o?p" \
        "all FIFTEEN enumerated code points are replaced, including each group's boundary"
    assert_not_contains "$RC_OUT" "$zwsp" "no raw zero-width space reaches the report"
    assert_not_contains "$RC_OUT" "$bom" "no raw BOM reaches the report"
}

test_ordinary_non_ascii_in_a_label_name_still_renders() {
    local box e raw
    box="$(make_sandbox status/in-progress)"
    # THE OTHER HALF OF THE PROPERTY, and the reason md_safe enumerates specific
    # characters instead of rejecting bytes above 0x7F. An accented character
    # carries no formatting power in GFM, so mangling it would destroy evidence
    # while buying no safety — the boundary is "characters that reorder or hide
    # text", not "non-ASCII".
    #
    # This case is what stops the fix from being over-tightened later: a future
    # edit that reached for `tr -d` over a byte range, or an `[:^ascii:]` class,
    # would pass every case above and redden only this one.
    e="$(command printf '\303\251')"
    raw="status/caf${e}-r${e}sum${e}"
    stub_gh "$box" ok status/in-progress "$raw"

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "the undeclared label is still reported as drift"
    assert_contains "$RC_OUT" "$raw" \
        "an accented label name reaches the report byte-for-byte unaltered"
    assert_not_contains "$RC_OUT" "caf?" "the accent is not replaced with a ?"
}
