# shellcheck shell=bash
# Input-shape guard (#816)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Input-shape guard (#816) ------------------------------------------------
#
# The gate takes a FILE LIST. Handed a DIFF it used to scan each diff line as a
# path, match nothing, and exit 0 -- output indistinguishable from a clean scan,
# on a pre-SHIP gate. These cases pin the three arms of the fix BEHAVIORALLY;
# tests/lint-prescan-input-guard.sh pins the guard's presence across all 40
# entry points structurally.
#
# run_gate captures stdout only, so these cases invoke the gate directly: two of
# the three arms are STDERR-and-exit-code contracts, and the empty-list case in
# particular is invisible to a stdout-only assertion (that is exactly how the
# mutation that drops the non-empty guard survived validate-prescans.sh).

# gate_streams <file-list> — run the gate, capturing stdout, stderr and rc
# separately into GS_OUT / GS_ERR / GS_RC.
GS_OUT=""
GS_ERR=""
GS_RC=0
gate_streams() {
    local errfile
    errfile="$(command mktemp)"
    GS_RC=0
    GS_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$1" 2>"$errfile")" || GS_RC=$?
    GS_ERR="$(command cat "$errfile")"
    command rm -f "$errfile"
}

# A diff is refused loudly: non-zero exit, actionable stderr, no findings.
# The fixture is a REAL diff (built by git), not a hand-written lookalike -- a
# fixture spelled to dodge the scanner's own pattern literals can pass with and
# without the fix.
test_diff_input_fails_loud() {
    local dir="$WORKDIR/diff-input"
    command mkdir -p "$dir/repo"
    (
        cd "$dir/repo" || exit 1
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git init -q .
        command printf 'const a = 1;\n' >file.js
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git add -A
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git -c user.email=t@t -c user.name=t commit -qm init
        command printf 'const a = 2;\n' >file.js
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git diff >"$dir/real.diff"
    )

    assert_file_contains "$dir/real.diff" "diff --git" "the fixture is a genuine git diff"

    gate_streams "$dir/real.diff"
    assert_exit 1 "$GS_RC" "a diff passed as a file list exits non-zero"
    assert_contains "$GS_ERR" "looks like a DIFF" "the error names the wrong input shape"
    assert_contains "$GS_ERR" "--name-only" "the error names the fix"
    assert_output_empty "$GS_OUT" "a refused diff emits no findings on stdout"
}

# The unified-diff body markers are caught too, not just the `diff --git`
# header: `git diff` output piped through a filter can lose the header while
# staying just as wrong an input.
test_headerless_diff_body_is_caught() {
    local dir="$WORKDIR/diff-body"
    command mkdir -p "$dir"
    local list="$dir/body.diff"
    {
        command printf -- '--- a/src/app.js\n'
        command printf -- '+++ b/src/app.js\n'
        command printf -- '@@ -1,3 +1,4 @@\n'
    } >"$list"

    gate_streams "$list"
    assert_exit 1 "$GS_RC" "a headerless diff body is refused too"
    assert_contains "$GS_ERR" "looks like a DIFF" "the body-marker arm reports the same diagnosis"
}

# A list whose paths do not resolve WARNS but still exits 0 -- it may name only
# deleted files, which is legitimate. This is the deliberate severity split.
test_unresolvable_list_warns_without_failing() {
    local dir="$WORKDIR/stale-list"
    command mkdir -p "$dir"
    local list="$dir/stale.txt"
    command printf 'no/such/file.js\nalso/missing.py\n' >"$list"

    gate_streams "$list"
    assert_exit 0 "$GS_RC" "an unresolvable list warns rather than failing"
    assert_contains "$GS_ERR" "no path listed in" "the warning names the symptom"
    assert_output_empty "$GS_OUT" "the warning does not contaminate the TSV stdout"
}

# The warning is guarded on a NON-EMPTY list. An empty list is the ordinary
# no-relevant-files-changed case and must stay COMPLETELY silent -- including on
# stderr. validate-prescans.sh asserts only stdout here, so without this case a
# dropped non-empty guard warns on every empty invocation and no test notices.
test_empty_list_stays_silent_on_stderr() {
    local dir="$WORKDIR/empty-silent"
    command mkdir -p "$dir"
    local list="$dir/empty.txt"
    : >"$list"

    gate_streams "$list"
    assert_exit 0 "$GS_RC" "an empty list still exits 0"
    assert_output_empty "$GS_OUT" "an empty list emits no findings"
    assert_output_empty "$GS_ERR" "an empty list emits NO WARNING — the guard is non-empty-gated"
}

# A list with one resolvable path does not warn, even though others are missing:
# the warning fires only when NOTHING resolves, so a diff deleting one file
# among many stays quiet.
test_partially_resolvable_list_does_not_warn() {
    local dir="$WORKDIR/partial"
    command mkdir -p "$dir"
    command printf 'let x = 1;\n' >"$dir/real.js"
    local list="$dir/files.txt"
    command printf '%s\ndeleted/gone.js\n' "$dir/real.js" >"$list"

    gate_streams "$list"
    assert_exit 0 "$GS_RC" "a partially-resolvable list exits 0"
    assert_true "! command printf '%s' \"$GS_ERR\" | command grep -q 'no path listed in'" \
        "one resolvable path suppresses the warning"
}

# The control: the guard must not change what a CORRECT invocation reports. A
# guard that also suppressed findings would trade one silent-zero for another.
test_guard_does_not_alter_normal_scan() {
    local dir="$WORKDIR/guard-control"
    command mkdir -p "$dir"
    command printf 'function orphan() { return 1; }\nconsole.log("x");\n' >"$dir/orphan.js"
    local list
    list="$(make_list "$dir" orphan.js)"

    gate_streams "$list"
    assert_exit 0 "$GS_RC" "a valid file list still exits 0"
    assert_not_empty "$GS_OUT" "a valid file list still produces findings"
    assert_not_empty "$(category_rows "$GS_OUT" debug-statement)" \
        "the debug-statement detector still fires through the guard"
}
