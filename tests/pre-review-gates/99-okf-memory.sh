# shellcheck shell=bash
# Memory-bundle conformance delegation (#699)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.
#
# The gate resolves check-okf-conformance/patterns.sh at RUNTIME -- the #708
# subprocess/TSV shape, not a `# >>> shared:` duplicate -- and hands it the same
# file list every other scanner reads.
#
# THE CENTRAL PROPERTY here is not "memory rows appear". It is that the arm reads
# WHOLE-BUNDLE while REPORTING DIFF-LOCAL, which is two claims that fail in
# opposite directions and so need two fixtures each with a leak case:
#
#   reports too much -> the raw scanner emits a row for EVERY file in the bundle.
#     Measured on this repo before scoping: one changed memory file produced 81
#     rows across 81 files. Unscoped, that is a wall of pre-existing debt charged
#     to whoever touched one memory, which is how a dimension gets switched off.
#   reads too little -> scoping by pre-filtering the scanner's INPUT would look
#     identical on the happy path but silently lose every graph finding: an
#     orphan is defined by the ABSENCE of a pointer anywhere in the bundle, so a
#     scanner shown only the changed file cannot see one.
#
# test_okf_graph_row_scoped_to_changed_file pins both at once: same bundle, same
# defect present on TWO files, only one of them in the diff. Asserting only the
# surviving row would pass with the filter removed
# ([[absence-assertion-needs-a-leak-fixture]]), so it asserts the suppressed file
# is ABSENT and the changed file is PRESENT.
#
# Absence of the sibling plugin is FORCED via OKF_SCANNER rather than skipped
# ([[self-skipping-test-hides-the-risky-branch]]).
#
# NOTE the disposition difference from 98-security.sh, which is deliberate and is
# the thing most likely to be "fixed" wrongly later: a missing security scanner
# FAILS LOUD, a missing OKF scanner DEGRADES QUIETLY. A memory bundle is optional
# and most repos have none, so a loud failure would fire on every repo the
# feature does not apply to. test_okf_absent_degrades_quietly pins that.

# okf_run <file-list> [okf-override] -- run the real gate capturing stdout,
# stderr and exit code into OKF_OUT / OKF_ERR / OKF_RC. Single-consumer, so it
# lives here rather than in the shared library.
#
# SECURITY_SCANNER is pinned to the REAL scanner throughout: these fixtures run
# the gate against a sandbox bundle, and without the pin the security arm refuses
# and the case goes red for the OTHER arm's reason.
OKF_OUT=""
OKF_ERR=""
OKF_RC=0
okf_run() {
    local list="$1" override="${2:-}"
    local outfile errfile
    outfile="$(command mktemp)"
    errfile="$(command mktemp)"
    OKF_RC=0
    if [ -n "$override" ]; then
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            "SECURITY_SCANNER=$SECURITY_SCANNER_REAL" "OKF_SCANNER=$override" \
            "$REAL_BASH" "$GATE" "$list" >"$outfile" 2>"$errfile" || OKF_RC=$?
    else
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            "SECURITY_SCANNER=$SECURITY_SCANNER_REAL" \
            "$REAL_BASH" "$GATE" "$list" >"$outfile" 2>"$errfile" || OKF_RC=$?
    fi
    OKF_OUT="$(command cat "$outfile")"
    OKF_ERR="$(command cat "$errfile")"
    command rm -f "$outfile" "$errfile"
}

# write_memory_bundle <dir> -- a minimal CONFORMANT bundle: an index naming
# kept.md, and kept.md carrying the frontmatter the schema floor requires.
# Cases mutate one file from here so the defect under test is the only variable.
write_memory_bundle() {
    local dir="$1"
    command mkdir -p "$dir/.claude/memory"
    command printf '%s\n' \
        '# Memory index' \
        '' \
        '- [Kept](kept.md) — a hook' \
        >"$dir/.claude/memory/MEMORY.md"
    write_memory_concept "$dir" kept
}

# write_memory_concept <dir> <name> -- a conformant concept file.
write_memory_concept() {
    local dir="$1" name="$2"
    command printf '%s\n' \
        '---' \
        "name: $name" \
        'description: one line' \
        'metadata:' \
        '  type: reference' \
        '---' \
        '' \
        'Body text.' \
        >"$dir/.claude/memory/$name.md"
}

# A changed memory file with a conformance defect (no `type`) produces a row.
# This is the baseline the whole slice exists for: before the delegation arm the
# gate emitted ZERO rows for any memory file.
test_okf_conformance_row_emitted() {
    local dir
    dir="$(fresh_dir)"
    write_memory_bundle "$dir"
    command printf '%s\n' \
        '---' \
        'name: broken' \
        'description: one line' \
        '---' \
        '' \
        'No metadata.type key.' \
        >"$dir/.claude/memory/broken.md"

    local list
    list="$(make_list "$dir" ".claude/memory/broken.md")"
    okf_run "$list"

    local rows
    rows="$(category_rows "$OKF_OUT" "okf-missing-type")"
    assert_not_empty "$rows" \
        "a changed memory file with no type emits okf-missing-type (#699)"
    assert_equals "HIGH" "$(field "$rows" 5)" \
        "okf-missing-type is HIGH — review-route.sh R4 keys off the certainty"
}

# The graph half, and the load-bearing case. An orphan is defined by the absence
# of a pointer ANYWHERE in the bundle, so this can only pass if the scanner reads
# the whole bundle; and the untouched file must NOT be reported, which can only
# pass if the OUTPUT is filtered rather than the input.
test_okf_graph_row_scoped_to_changed_file() {
    local dir
    dir="$(fresh_dir)"
    write_memory_bundle "$dir"
    # Empty the index so BOTH concepts are orphans — same defect, two files.
    command printf '%s\n' '# Memory index' '' 'No entries.' \
        >"$dir/.claude/memory/MEMORY.md"
    write_memory_concept "$dir" orphan

    # Only orphan.md is in the diff; kept.md is equally defective and untouched.
    local list
    list="$(make_list "$dir" ".claude/memory/orphan.md")"
    okf_run "$list"

    local rows
    rows="$(category_rows "$OKF_OUT" "memory-orphan")"
    assert_not_empty "$rows" \
        "an orphan introduced by the diff IS detected — the scanner reads the whole bundle (#699 AC#2)"

    # The leak assertion. Without the output filter the raw scanner emits a
    # memory-orphan row for kept.md too, so this is what proves the scoping.
    local leaked
    leaked="$(command printf '%s\n' "$rows" | command grep -c 'kept\.md' || true)"
    assert_equals "0" "$leaked" \
        "the equally-orphaned UNTOUCHED file is not reported — reporting is diff-local (#699 AC#2)"

    local kept_present
    kept_present="$(command printf '%s\n' "$rows" | command grep -c 'orphan\.md' || true)"
    assert_equals "1" "$kept_present" \
        "exactly the changed file is reported"
}

# AC#8: a repo with no memory bundle reviews cleanly — no findings, no error.
# This is the case that makes the graceful-degradation disposition necessary:
# most repos have no bundle at all.
test_okf_no_bundle_reviews_cleanly() {
    local dir
    dir="$(fresh_dir)"
    command printf '%s\n' '# readme' >"$dir/README.md"

    local list
    list="$(make_list "$dir" "README.md")"
    okf_run "$list"

    assert_exit 0 "$OKF_RC" "a repo with no memory bundle exits 0 (#699 AC#8)"
    local rows
    rows="$(command printf '%s\n' "$OKF_OUT" | command grep -cE '	okf-|	memory-' || true)"
    assert_equals "0" "$rows" \
        "a repo with no memory bundle emits no okf/memory rows (#699 AC#8)"
}

# Absence degrades QUIETLY — deliberately unlike the security arm. The gate must
# still exit 0 and still emit its own rows; only the memory opinion is missing.
test_okf_absent_degrades_quietly() {
    local dir
    dir="$(fresh_dir)"
    write_memory_bundle "$dir"
    command printf '%s\n' \
        '---' 'name: broken' 'description: one line' '---' '' 'No type.' \
        >"$dir/.claude/memory/broken.md"
    # A file whose own detectors fire, so "the rest of the gate still works" is
    # observable rather than assumed from an empty output.
    command printf '%s\n' 'def f():' '    print("debug")' >"$dir/app.py"

    local list
    list="$(make_list "$dir" ".claude/memory/broken.md" "app.py")"
    okf_run "$list" "$dir/definitely-not-a-scanner.sh"

    assert_exit 0 "$OKF_RC" \
        "an absent OKF scanner does NOT fail the gate — a memory opinion is optional, unlike a security scan (#699)"
    local rows
    rows="$(command printf '%s\n' "$OKF_OUT" | command grep -cE '	okf-|	memory-' || true)"
    assert_equals "0" "$rows" "an absent OKF scanner emits no memory rows"

    # QUIET means quiet on STDERR too. The security arm deliberately prints an
    # actionable install message when its scanner is missing; this arm must not,
    # or every repo without a memory bundle gets a warning about a feature that
    # does not apply to it. Asserting the exit code alone would not catch that
    # ([[redirect-order-leaks-the-diagnostic]]).
    local noise
    noise="$(command printf '%s\n' "$OKF_ERR" | command grep -ciE 'okf|memory' || true)"
    assert_equals "0" "$noise" \
        "an absent OKF scanner says nothing on stderr — absence is the normal case, not a warning (#699)"
    assert_not_empty "$(category_rows "$OKF_OUT" "debug-statement")" \
        "the rest of the gate still reports — the arm degraded, it did not abort"
}

# AC#9: memory CONTENT must never reach a PR comment. The evidence column is what
# gets rendered into one, so it must describe the defect structurally and must
# not echo the body text.
test_okf_never_prints_memory_content() {
    local dir secret
    dir="$(fresh_dir)"
    secret="CANARY-MEMORY-BODY-TEXT"
    write_memory_bundle "$dir"
    command printf '%s\n' \
        '---' 'name: broken' 'description: one line' '---' '' "$secret" \
        >"$dir/.claude/memory/broken.md"

    local list
    list="$(make_list "$dir" ".claude/memory/broken.md")"
    okf_run "$list"

    assert_not_empty "$(category_rows "$OKF_OUT" "okf-missing-type")" \
        "the fixture actually tripped a detector — otherwise the canary check is vacuous"
    local leaked
    leaked="$(command printf '%s\n' "$OKF_OUT" | command grep -c "$secret" || true)"
    assert_equals "0" "$leaked" \
        "memory body text never reaches the TSV evidence (#699 AC#9)"
}

# The category slugs the gate emits must be the ones review-route.sh's R4 knows,
# or R4 is inert for OKF rows and a memory PR silently routes cheap. This is not
# hypothetical: the R4 comment records that a prior review caught three INVENTED
# names (okf-orphaned, okf-dangling-index, memory-conformance) that could never
# have matched. Derived from both files rather than retyped here, so the two
# cannot drift apart without this failing.
test_okf_categories_known_to_router() {
    local scanner router slug
    scanner="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.sh"
    router="$REPO_ROOT/plugins/workflow/scripts/review-route.sh"

    if [ ! -f "$scanner" ] || [ ! -f "$router" ]; then
        skip_test "check-okf-conformance or review-route.sh not present"
        return
    fi

    # The slugs the scanner actually emits, read off its category constants.
    local slugs
    slugs="$(command grep -oE '"(okf|memory)-[a-z-]+"' "$scanner" |
        command tr -d '"' | command sort -u)"
    assert_not_empty "$slugs" \
        "the scanner's category constants are discoverable — otherwise this test proves nothing"

    local missing=""
    for slug in $slugs; do
        if ! command grep -q -- "$slug" "$router"; then
            missing="$missing $slug"
        fi
    done
    assert_equals "" "$missing" \
        "every okf/memory category the scanner emits is known to review-route.sh R4 (#699)"
}
