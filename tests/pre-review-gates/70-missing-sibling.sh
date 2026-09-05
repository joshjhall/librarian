# shellcheck shell=bash
# Missing sibling test-discovery.sh fails loud + diff-refusal control-byte stripping (#816)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# The sibling test-discovery.sh (#816) is a HARD dependency: pre-review-gates.sh
# sources it for the whole missing-test-file category. Absent, the gate must
# refuse rather than run a scan that silently omits one of its four categories --
# a partial scan reported as a pass is the very failure #816 exists to close, and
# this repo's #538/#571 sentinel discipline requires a fail-loud path to be
# VERIFIED, not merely written.
#
# Shaped after test_plan_lens_fails_loud_without_engine in
# tests/validate-plan-lens.sh, the established precedent for a missing-sibling
# guard. Note the deliberate contrast with
# test_missing_sizing_does_not_abort_the_scan, which COPIES test-discovery.sh in
# so it can isolate a missing sizing.sh: sizing degrades gracefully (its rows are
# supplementary), while test-discovery does not (its absence removes a category).
# The two tests together pin that asymmetry -- neither alone shows it is
# deliberate.
test_missing_test_discovery_fails_loud() {
    local iso="$WORKDIR/no-test-discovery" rc=0 err
    command mkdir -p "$iso"

    # Copy ONLY the entry point. The sourced sibling is what is under test by
    # its absence, so it must not come along.
    command cp "$GATE" "$iso/pre-review-gates.sh"
    command cp "${GATE%/*}/sizing.sh" "$iso/sizing.sh" 2>/dev/null || true

    local dir="$WORKDIR/no-td-src"
    command mkdir -p "$dir"
    command printf 'let x = 1;\n' >"$dir/thing.js"
    local list
    list="$(make_list "$dir" thing.js)"

    local outfile errfile
    outfile="$(command mktemp)"
    errfile="$(command mktemp)"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$iso/pre-review-gates.sh" "$list" >"$outfile" 2>"$errfile" || rc=$?
    err="$(command cat "$errfile")"
    local out
    out="$(command cat "$outfile")"
    command rm -f "$outfile" "$errfile"

    assert_exit 1 "$rc" \
        "with no sibling test-discovery.sh the gate exits 1, NOT 0-with-a-partial-scan"
    assert_contains "$err" "requires the sibling test-discovery.sh" \
        "the refusal names the missing dependency"
    assert_contains "$err" "refuses to report a clean scan" \
        "the refusal says why silence would be wrong"
    assert_output_empty "$out" \
        "a refused scan emits no findings — a partial TSV must not look like a result"
}

# The offending line is reflected to the operator's terminal, and the input is
# caller-supplied -- in this repo's stated hostile-repo posture it can come from
# an audited PR's diff. Raw ESC/BEL would render as live control sequences
# (cursor moves, hidden output, an OSC title-bar write), so they are stripped.
# The fixture carries REAL control bytes, not backslash-escapes: a `\033`
# written literally would prove nothing, since it is already inert text.
test_diff_refusal_strips_control_bytes() {
    local dir="$WORKDIR/esc-inject"
    command mkdir -p "$dir"
    local list="$dir/esc.txt"
    command printf 'diff --git \033[31mRED\033[0m\033]0;PWNED\007tail\n' >"$list"

    # Guard the fixture itself: if printf did not emit a real ESC, the test below
    # would pass vacuously.
    assert_true "command grep -q \"$(command printf '\033')\" '$list'" \
        "the fixture actually contains a raw ESC byte"

    local errfile rc=0
    errfile="$(command mktemp)"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$list" >/dev/null 2>"$errfile" || rc=$?
    local err
    err="$(command cat "$errfile")"
    command rm -f "$errfile"

    assert_exit 1 "$rc" "a control-byte-bearing diff is still refused"
    assert_contains "$err" "Offending line:" "the line is still reported"
    assert_true "! command printf '%s' \"$err\" | command grep -q \"$(command printf '\033')\"" \
        "no raw ESC byte survives into the reflected message"
    assert_true "! command printf '%s' \"$err\" | command grep -q \"$(command printf '\007')\"" \
        "no raw BEL byte survives into the reflected message"
    assert_contains "$err" "tail" "the printable remainder of the line is preserved"
}

# The MULTI-BYTE half of the same defence, and the reason it needs its own case:
# `tr` is byte-wise, so it cannot express a Unicode format character. A bidi
# override (U+202E) makes the reflected path RENDER reversed -- a hostile
# `a/<RTLO>evil.js` can display as something else entirely -- and the zero-width
# family hides characters outright. The python primary gets these for free via
# isprintable() (category Cf), so WITHOUT the sed pass the two runtimes diverge
# on exactly the path the bash fallback exists to serve. Measured before the fix:
# RTLO survived in bash, was stripped in python.
#
# Fixture is built by python from code points, not typed inline: the raw bytes
# are invisible in a terminal and in a diff, and a `\u202e`-style escape written
# into the file would be inert text that cannot self-match (this repo's known
# tautology shape).
test_diff_refusal_strips_unicode_format_chars() {
    local dir="$WORKDIR/uni-inject"
    command mkdir -p "$dir"
    local list="$dir/uni.txt"

    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 unavailable — cannot build the multi-byte fixture"
        return 0
    fi
    command python3 -c 'import sys
names = {"RTLO": 0x202E, "ZWSP": 0x200B, "LRI": 0x2066, "BOM": 0xFEFF, "RLM": 0x200F}
line = "diff --git a/" + "".join(chr(c) + n for n, c in names.items()) + "tail"
open(sys.argv[1], "w").write(line + "\n")' "$list"

    # Arm the test: if the fixture lost its multi-byte bytes, everything below
    # passes vacuously.
    assert_true "command grep -q \"$(command python3 -c 'print(chr(0x202E))')\" '$list'" \
        "the fixture actually contains a raw U+202E byte sequence"

    local errfile rc=0
    errfile="$(command mktemp)"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$list" >/dev/null 2>"$errfile" || rc=$?
    local err
    err="$(command cat "$errfile")"
    command rm -f "$errfile"

    assert_exit 1 "$rc" "a bidi-bearing diff is still refused"
    assert_true "! command printf '%s' \"$err\" | command grep -q \"$(command python3 -c 'print(chr(0x202E))')\"" \
        "no bidi override survives into the reflected message"
    assert_true "! command printf '%s' \"$err\" | command grep -q \"$(command python3 -c 'print(chr(0x200B))')\"" \
        "no zero-width space survives into the reflected message"
    assert_contains "$err" "RTLO" "the printable text around the stripped bytes is preserved"
    assert_contains "$err" "tail" "the line is not truncated at the first stripped byte"
}
