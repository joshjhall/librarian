# shellcheck shell=bash
# Result-file provenance (#1150) — review-convergence tests.
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.
#
# Every refusal case is paired with the positive control
# (test_matching_provenance_yields_a_verdict), which uses the SAME stamped
# shape with agreeing values — so a refusal cannot pass merely because a
# stamped file is unreadable to the script for some unrelated reason.

# stamped <name> <cycle-json> <issue-json> <blocking-json> — write a result
# fixture carrying provenance. The provenance args are raw JSON so a case can
# pass `null`, a string, or omit nothing by accident. Single-area helper, so it
# lives here rather than in the shared sandbox.
stamped() {
    command printf '{"cycle":%s,"issue":%s,"blocking":[%s],"deferrable":[]}\n' \
        "$2" "$3" "$4" >"$FIXTURES/prov-$1.json"
    command printf '%s' "$FIXTURES/prov-$1.json"
}

# refused <label> <args...> — run check, assert exit 2 AND that no verdict was
# printed. Leaves stderr in REFUSED_ERR for the caller's message assertions.
# Sets a global rather than echoing, because a caller capturing it with `$(...)`
# would run these assertions in a subshell and silently lose their counts.
REFUSED_ERR=""
refused() {
    local label="$1" rc=0 out errf
    shift
    errf="$(command mktemp)"
    out="$("$RC" check "$@" 2>"$errf")" || rc=$?
    REFUSED_ERR="$(command cat "$errf")"
    command rm -f "$errf"
    assert_exit "2" "$rc" "$label exits 2"
    assert_not_contains "$out" "verdict=" "$label emits no verdict on stdout"
}

test_foreign_issue_result_is_refused_not_stopped() {
    # The #1145 replay: a ZERO-finding file left by another issue's run. Read
    # as-is it is a C4-zero stop; with --issue it must be a refusal instead.
    local f err
    f="$(stamped foreign-zero 1 999 "")"
    assert_equals "stop" "$(val verdict "$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$f" --delta-lines 40)")" "precondition: unchecked, the foreign zero reads as stop"
    refused "a foreign-issue --result" --cycle 1 --max-cycles 5 --issue 1150 \
        --result "$f" --delta-lines 40
    err="$REFUSED_ERR"
    assert_contains "$err" "has issue 999, not --issue 1150" "the message names both issues"
    assert_contains "$err" "re-extract" "the message says what to do"
}

test_result_without_issue_is_refused_when_issue_is_asserted() {
    local f err
    f="$(stamped no-issue 1 null "")"
    refused "an unstamped --result under --issue" --cycle 1 --max-cycles 5 --issue 1150 \
        --result "$f" --delta-lines 40
    err="$REFUSED_ERR"
    assert_contains "$err" "has issue null" "a missing issue is a mismatch, not a pass"
    # Re-extracting cannot fix a null stamp, so the message must not send the
    # operator round that loop: it names the harness args instead.
    assert_contains "$err" "re-run the harness with issue: { number: 1150 }" \
        "a null stamp points at the harness args, not at re-extraction"
}

test_string_issue_does_not_match_the_number() {
    # A string "1150" is not the harness's integer stamp; tojson keeps the two
    # distinct, so a templated file cannot pass by coincidence of spelling.
    local f
    f="$(stamped string-issue 1 '"1150"' "")"
    refused "a string-typed issue" --cycle 1 --max-cycles 5 --issue 1150 \
        --result "$f" --delta-lines 40
}

test_foreign_cycle_result_is_refused_without_issue() {
    # No --issue at all: the cycle check needs no new flag, so the pre-#1094
    # recipe (which never passes --issue) is protected too.
    local f err
    f="$(stamped old-cycle 1 1150 "")"
    refused "a cycle-1 file read as cycle 2" --cycle 2 --max-cycles 5 \
        --result "$f" --delta-lines 40
    err="$REFUSED_ERR"
    assert_contains "$err" "is for cycle 1, not --cycle 2" "the message names both cycles"
}

test_foreign_cycle_result_is_refused_with_matching_issue() {
    # Right issue, wrong cycle: the reused-filename-after-a-failed-write case.
    local f
    f="$(stamped same-issue-old-cycle 1 1150 "")"
    refused "a right-issue wrong-cycle --result" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$f" --delta-lines 40
}

test_foreign_prev_result_is_refused_on_a_zero_cycle() {
    # The CURRENT result is clean and correctly stamped, so the duplicate loop
    # (which only reads --prev-result when total > 0) would never open the
    # foreign file. The refusal must not depend on that loop.
    local cur prev err
    cur="$(stamped cur-zero 2 1150 "")"
    prev="$(stamped prev-foreign 1 999 "$(finding src/a.js 10 correctness R8-defect-in-new-code)")"
    refused "a foreign --prev-result" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$prev" --delta-lines 40 --prev-delta-lines 40
    err="$REFUSED_ERR"
    assert_contains "$err" "prior-cycle result" "the message says which file was foreign"
    assert_contains "$err" "has issue 999" "the message names the foreign issue"
}

test_foreign_prev_result_is_refused_among_valid_ones() {
    # The bad file is the SECOND --prev-result: every occurrence is checked,
    # not only the first.
    local cur good bad
    cur="$(stamped cur-novel 3 1150 "$(finding src/b.js 20 correctness R8-defect-in-new-code)")"
    good="$(stamped prev-good 1 1150 "")"
    bad="$(stamped prev-bad 2 42 "")"
    refused "a foreign second --prev-result" --cycle 3 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$good" --prev-result "$bad" --delta-lines 40
}

test_matching_provenance_yields_a_verdict() {
    # Positive control for every refusal above: same stamped shape, agreeing
    # values, and a prior cycle whose cycle number differs (as it must).
    local cur prev out rc=0
    cur="$(stamped ok-cur 2 1150 "$(finding src/c.js 30 correctness R8-defect-in-new-code)")"
    prev="$(stamped ok-prev 1 1150 "$(finding src/a.js 10 correctness R8-defect-in-new-code)")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --issue 1150 --result "$cur" \
        --prev-result "$prev" --delta-lines 40 --prev-delta-lines 40)" || rc=$?
    assert_exit "0" "$rc" "matching provenance exits 0"
    assert_equals "C8-novel" "$(val rule "$out")" "matching provenance reaches the rule list"
}

test_unstamped_result_without_issue_is_unchanged() {
    # Back-compat: a file with no provenance fields and no --issue decides
    # exactly as before #1150.
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 40)"
    assert_equals "C4-zero" "$(val rule "$out")" "an unstamped result still decides without --issue"
}

test_bad_issue_value_fails_loud() {
    local v err
    for v in 0 07 x -3; do
        refused "--issue '$v'" --cycle 1 --max-cycles 5 --issue "$v" \
            --result "$FIXTURES/zero.json" --delta-lines 40
        err="$REFUSED_ERR"
        assert_contains "$err" "--issue must be an integer >= 1" "--issue '$v' names the flag"
    done
}

test_string_cycle_does_not_match_the_number() {
    # The cycle twin of the string-issue case: "1" is not the integer 1.
    local f
    f="$(stamped string-cycle '"1"' 1150 "")"
    refused "a string-typed cycle" --cycle 1 --max-cycles 5 --issue 1150 \
        --result "$f" --delta-lines 40
}

test_unusable_prev_result_is_refused_on_a_zero_cycle() {
    # check_provenance validates its own input because it runs BEFORE
    # read_findings, and on a zero-finding cycle read_findings never opens a
    # --prev-result at all. Each shape must exit 2 with no verdict.
    local cur
    cur="$(stamped cur-zero-unusable 2 1150 "")"
    command printf 'not json\n' >"$FIXTURES/prov-invalid.json"
    command printf '[1,2]\n' >"$FIXTURES/prov-array.json"
    refused "a missing --prev-result" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$FIXTURES/prov-does-not-exist.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "cannot read result file" "a missing --prev-result names the read failure"
    refused "an invalid-JSON --prev-result" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$FIXTURES/prov-invalid.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "is not valid JSON" "an invalid --prev-result names the parse failure"
    refused "an array --prev-result" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$FIXTURES/prov-array.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "has issue null" "a non-object --prev-result reads as unstamped, not a jq crash"
}

test_unstamped_prev_result_is_refused_under_issue() {
    # The prev role's null-stamp branch: a prior file with `issue: null` must be
    # refused with the prior-cycle wording, not accepted as "no stamp, no check".
    local cur prev
    cur="$(stamped cur-zero-nullprev 2 1150 "")"
    prev="$(stamped prev-null 1 null "")"
    refused "an unstamped --prev-result under --issue" --cycle 2 --max-cycles 5 --issue 1150 \
        --result "$cur" --prev-result "$prev" --delta-lines 40
    assert_contains "$REFUSED_ERR" "prior-cycle result" "the null prev names its role"
    assert_contains "$REFUSED_ERR" "has issue null" "the null prev names the missing stamp"
}
