# shellcheck shell=bash
# test_discovery: literal templates (#601)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- test_discovery: literal templates (#601) --------------------------------
#
# An entry with no `{name}` is a CONSTANT, not a template: it resolves to the
# same existing path for every source, so has_declared_test() is true for all of
# them and scan_missing_tests returns early for the ENTIRE run. The scan still
# exits 0 and still prints its other categories — a silent false negative in the
# very key #568 added as the supported escape hatch.
#
# Each case below plants TWO unrelated sources so "the whole run went quiet" is
# distinguishable from "one file was suppressed".

# write_discovery_sandbox <varname> <entry...> — a sandbox with two unrelated
# python sources, a real tests/ tree holding a test for ONE of them
# (validate-alpha.sh, matching the tests/validate-{name}.sh convention), and a
# pre-review.yml declaring the given test_discovery entries. Echoes the file
# list path via the second varname-free convention used elsewhere in this file.
DISCOVERY_LIST=""
write_discovery_sandbox() {
    local __out="$1" __dir=""
    shift
    # NOTE: the scratch variable is __dir, deliberately NOT the same name the
    # callers pass in (`sb`). new_git_sandbox assigns through `printf -v "$1"`,
    # so a local of that name here would shadow the caller's and the value would
    # never escape this frame — under `set -u` the caller then dies on an unbound
    # `sb` rather than getting a wrong-but-quiet answer.
    new_git_sandbox __dir || return 1
    command mkdir -p "$__dir/.claude" "$__dir/tests"
    command printf '%s\n' "def alpha_public():" "    return 1" >"$__dir/alpha.py"
    command printf '%s\n' "def beta_public():" "    return 2" >"$__dir/beta.py"
    # A real file for a literal entry to point at, and the conventional test for
    # alpha.py so a VALID template has something to resolve to.
    command printf '%s\n' "#!/usr/bin/env bash" "echo hi" >"$__dir/tests/validate-seed-trust.sh"
    command printf '%s\n' "#!/usr/bin/env bash" "alpha_public" >"$__dir/tests/validate-alpha.sh"
    {
        command printf '%s\n' "test_discovery:"
        local e
        for e in "$@"; do
            command printf '  - "%s"\n' "$e"
        done
    } >"$__dir/.claude/pre-review.yml"
    DISCOVERY_LIST="$__dir/files.txt"
    command printf '%s\n' "$__dir/alpha.py" "$__dir/beta.py" >"$DISCOVERY_LIST"
    printf -v "$__out" '%s' "$__dir"
}

# The defect itself: a literal entry took missing-test-file to zero rows for
# every file in the scan. Both sources must still be reported.
test_literal_test_discovery_does_not_silence() {
    local sb rows
    write_discovery_sandbox sb "tests/validate-seed-trust.sh" || return 1
    run_gate_in "$sb" "$DISCOVERY_LIST"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "alpha.py" \
        "a literal test_discovery entry does not silence alpha.py (#601)"
    assert_contains "$rows" "beta.py" \
        "...nor the unrelated beta.py — the whole run stayed live (#601)"
}

# The failure was INVISIBLE, so rejecting the entry silently would only convert
# one silent wrong answer into another. The warning must reach stderr, and must
# NOT reach stdout (which carries the TSV the review harness parses).
test_literal_test_discovery_warns() {
    local sb
    write_discovery_sandbox sb "tests/validate-seed-trust.sh" || return 1
    run_gate_in_err "$sb" "$DISCOVERY_LIST"

    assert_contains "$GATE_ERR" "tests/validate-seed-trust.sh" \
        "the warning names the offending entry (#601)"
    assert_contains "$GATE_ERR" "{name}" \
        "the warning states what the entry is missing (#601)"
    assert_not_contains "$GATE_OUT" "Warning" \
        "the warning stays off stdout, which carries the TSV contract (#601)"
}

# Regression guard for #568's actual feature: rejecting literals must not break
# real templates. alpha.py HAS tests/validate-alpha.sh, beta.py has nothing —
# so exactly one row, not zero (over-rejection) and not two (feature dead).
test_templated_test_discovery_still_resolves() {
    local sb rows
    write_discovery_sandbox sb "tests/validate-{name}.sh" || return 1
    run_gate_in_err "$sb" "$DISCOVERY_LIST"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "alpha.py" \
        "a resolving {name} template still suppresses its source (#568 intact)"
    assert_contains "$rows" "beta.py" \
        "...while a source the template cannot resolve still fires (#568 intact)"
    assert_not_contains "$GATE_ERR" "Warning" \
        "a wholly valid config produces no warning noise"
}

# The realistic config: someone adds a literal alongside working templates. The
# literal must be dropped WITHOUT taking the valid entry with it — a coarse
# "any bad entry disables the key" fix would pass the two cases above and fail
# here.
test_mixed_test_discovery_keeps_valid_entry() {
    local sb rows
    write_discovery_sandbox sb "tests/validate-seed-trust.sh" "tests/validate-{name}.sh" || return 1
    run_gate_in_err "$sb" "$DISCOVERY_LIST"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "alpha.py" \
        "the valid template still resolves despite a literal sibling (#601)"
    assert_contains "$rows" "beta.py" \
        "the unresolvable source still fires (#601)"
    assert_contains "$GATE_ERR" "tests/validate-seed-trust.sh" \
        "the literal sibling is still named in the warning (#601)"
}

# The accumulator itself: every case above drops at most ONE entry, so a defect
# that only shows with 2+ (the join corrupting a neighbour, or only the first or
# last being reported) would go unseen. Two literals plus a valid template also
# pins that rejection is per-entry, not a latch that trips once.
test_multiple_literals_all_reported() {
    local sb rows
    write_discovery_sandbox sb \
        "tests/validate-seed-trust.sh" \
        "tests/validate-other.sh" \
        "tests/validate-{name}.sh" || return 1
    # The second literal needs to exist too, or it would be dropped by the
    # `[ -f ]` probe rather than by the {name} check — testing nothing.
    command printf '%s\n' "#!/usr/bin/env bash" "echo hi" \
        >"$sb/tests/validate-other.sh"

    run_gate_in_err "$sb" "$DISCOVERY_LIST"

    assert_contains "$GATE_ERR" "tests/validate-seed-trust.sh" \
        "the FIRST literal is named in the warning (#601)"
    assert_contains "$GATE_ERR" "tests/validate-other.sh" \
        "the SECOND literal is named too — not just one of them (#601)"
    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "alpha.py" \
        "the valid template still resolves past TWO rejected siblings (#601)"
    assert_contains "$rows" "beta.py" \
        "the unresolvable source still fires (#601)"
}
