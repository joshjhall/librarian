# shellcheck shell=bash
# Sizing delegation (#695)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- sizing delegation (#695) ------------------------------------------------
# The gate grew an optional `$2` numstat sidecar and a tail block delegating to
# the sibling sizing.sh. Three behaviors are pinned HERE, through the real gate,
# because validate-sizing-scanner.sh exercises sizing.sh DIRECTLY and so cannot
# see the wiring: whether the delegation happens at all, whether the sidecar is
# forwarded, and whether a missing sizing.sh degrades gracefully.
#
# run_gate() takes a single argument, so these call the gate directly.

# gate_with_numstat FILE_LIST NUMSTAT — run the real gate with both arguments.
gate_with_numstat() {
    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$1" "$2" 2>/dev/null)" || GATE_RC=$?
}

# A file comfortably over the shell review threshold (700 production LOC).
make_big_sh() {
    local path="$1" i=0
    : >"$path"
    while [ "$i" -lt 400 ]; do
        command printf 'fn_%d() {\n    echo %d\n}\n' "$i" "$i" >>"$path"
        i=$((i + 1))
    done
}

# WITH a sidecar the rows are growth-graded: a big add is actionable.
test_sizing_rows_reach_the_gate_output() {
    local d rows
    d="$(fresh_dir)"
    make_big_sh "$d/big.sh"
    command printf '900\t0\t%s\n' "$d/big.sh" >"$d/numstat.txt"
    gate_with_numstat "$(make_list "$d" big.sh)" "$d/numstat.txt"

    rows="$(category_rows "$GATE_OUT" "file-length")"
    assert_contains "$rows" "big.sh" "the gate delegates to sizing and emits file-length rows (#695)"
    assert_contains "$rows" "pushed it over" "the numstat sidecar is FORWARDED (growth-graded evidence)"
    assert_equals "0" "$GATE_RC" "the gate still exits 0 with sizing wired in"
}

# WITHOUT a sidecar sizing still runs, but every row degrades to informational —
# the safe direction, since it cannot manufacture a blocking finding. Pinning
# both arms is what stops the forwarding being silently dropped: a gate that
# ignored $2 entirely would still pass the previous test's first assertion.
test_sizing_without_numstat_degrades_to_informational() {
    local d rows
    d="$(fresh_dir)"
    make_big_sh "$d/big.sh"
    run_gate "$(make_list "$d" big.sh)"

    rows="$(category_rows "$GATE_OUT" "file-length")"
    assert_contains "$rows" "big.sh" "sizing still runs with no sidecar"
    assert_contains "$rows" "no diff growth data supplied" "with no sidecar the row is informational"
    assert_not_contains "$rows" "pushed it over" "with no sidecar nothing claims the diff crossed a threshold"
}

# GRACEFUL DEGRADATION: the gate's own contract is that a missing scanner is
# skipped with a note, never a hard-fail. Asserted by pointing the gate at a copy
# of itself with no sizing.sh sibling — forcing the absent arm rather than
# trusting the `[ -f ]` guard by inspection (the self-skipping-test lesson).
test_missing_sizing_does_not_abort_the_scan() {
    local d rows
    d="$(fresh_dir)"
    command mkdir -p "$d/gatedir"
    command cp "$GATE" "$d/gatedir/pre-review-gates.sh"
    # The sourced sibling MUST come along: this fixture isolates a missing
    # sizing.sh, and test-discovery.sh (#816) is a hard dependency whose absence
    # is a different, deliberately fatal condition. Copying only the entry point
    # would make this case fail for the wrong reason and quietly stop testing
    # graceful degradation at all.
    command cp "${GATE%/*}/test-discovery.sh" "$d/gatedir/test-discovery.sh"
    make_big_sh "$d/big.sh"
    command printf '%s\n' "def f():" "    print('debug')" >"$d/app.py"

    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$d/gatedir/pre-review-gates.sh" "$(make_list "$d" big.sh app.py)" 2>/dev/null)" || GATE_RC=$?

    assert_equals "0" "$GATE_RC" "a missing sizing.sh does not fail the gate"
    rows="$(category_rows "$GATE_OUT" "file-length")"
    assert_equals "" "$rows" "no sizing rows when the sibling scanner is absent"
    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "app.py" "the OTHER scanners still ran (degradation is graceful, not fatal)"
}
