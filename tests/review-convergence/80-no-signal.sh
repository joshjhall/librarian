# shellcheck shell=bash
# C0/C0b — a crashed cycle produces no review signal (#616) — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- C0/C0b: a crashed cycle produces no review signal (#616) ---------------

test_no_signal_cycle_does_not_stop_at_the_cycle_cap() {
    # The core of #616. At cycle 5 of 5 — where C1 would fire — a cycle that died
    # before any dimension ran must NOT end the review: it produced no evidence
    # about convergence, so charging it to the cap would let three infra flakes
    # dead-end a PR having reviewed nothing.
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --attempt 5 --max-attempts 10 \
        --result "$FIXTURES/no-signal.json" --delta-lines 0 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a no-signal cycle does not consume the cap"
    assert_equals "C0b-no-signal" "$(val rule "$out")" "C0b outranks C1 for a crashed cycle"
}

test_no_signal_pair_differs_only_in_the_flag() {
    # ANTI-TAUTOLOGY pair: identical flags, identical finding content, and the
    # fixtures differ ONLY in `no_review_signal`. A detector that ignores the
    # field returns the same rule for both, so the pair cannot both pass unless
    # the field is genuinely read.
    local crashed complete
    crashed="$("$RC" check --cycle 5 --max-cycles 5 --attempt 5 --max-attempts 10 \
        --result "$FIXTURES/no-signal.json" --delta-lines 0 --partial false)"
    complete="$("$RC" check --cycle 5 --max-cycles 5 --attempt 5 --max-attempts 10 \
        --result "$FIXTURES/no-signal-false.json" --delta-lines 0 --partial false)"
    assert_equals "C0b-no-signal" "$(val rule "$crashed")" "the crashed cycle is uncharged"
    assert_equals "C1-cap" "$(val rule "$complete")" "the complete cycle still hits the cap"
}

test_attempt_cap_terminates_a_persistently_crashing_loop() {
    # C0b returns `continue` unconditionally, so without an attempts ceiling a
    # harness that crashes every time would loop forever. This is the
    # termination guarantee that replaces C1's for the no-signal path — driven as
    # a real loop, like the AC#3 integration test above.
    local attempt=1 verdict="" rule="" out iterations=0
    while [ "$iterations" -lt 30 ]; do
        iterations=$((iterations + 1))
        out="$("$RC" check --cycle 1 --max-cycles 5 --attempt "$attempt" --max-attempts 8 \
            --result "$FIXTURES/no-signal.json" --delta-lines 0 --partial false)"
        verdict="$(val verdict "$out")"
        rule="$(val rule "$out")"
        [ "$verdict" = "stop" ] && break
        attempt=$((attempt + 1))
    done
    assert_equals "stop" "$verdict" "a persistently crashing loop still terminates"
    assert_equals "C0-attempt-cap" "$rule" "it terminates at the ATTEMPT cap, not the cycle cap"
    assert_equals "8" "$attempt" "it stops exactly at max-attempts"
}

test_attempt_cap_outranks_everything() {
    # C0 is the new absolute ceiling: it must fire even on a cycle carrying novel
    # material AND a partial flag, the two rules that otherwise say `continue`.
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 8 --max-attempts 8 \
        --result "$FIXTURES/novel.json" --delta-lines 400 --partial true)"
    assert_equals "stop" "$(val verdict "$out")" "the attempt cap stops a productive partial cycle"
    assert_equals "C0-attempt-cap" "$(val rule "$out")" "C0 outranks C0b, C1 and C2"
}

test_no_signal_does_not_affect_an_ordinary_cycle() {
    # The complement: a normal cycle below the cap is unchanged by the new rules.
    # Without this, a C0b that fired too eagerly would silently convert every
    # convergence stop into a `continue` and defeat the early-stop half of #596.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 --max-attempts 10 \
        --result "$FIXTURES/zero.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "an ordinary converged cycle still stops"
    assert_equals "C4-zero" "$(val rule "$out")" "the convergence rule still decides"
}

test_string_false_is_not_read_as_no_signal() {
    # jq truthiness would accept the STRING "false" as no-signal and stop
    # charging the cycle cap. Only a literal boolean `true` may take the
    # uncharged path.
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/no-signal-string.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C1-cap" "$(val rule "$out")" "a string flag value is not a no-signal cycle"
}

test_absent_no_signal_field_reads_as_an_ordinary_cycle() {
    # Backward compatibility: a result file from a harness predating #616 has no
    # such field. It must read as an ordinary cycle, not silently become
    # uncharged (which would make every legacy cycle stop consuming the cap).
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C1-cap" "$(val rule "$out")" "an absent flag is not no-signal"
}

test_non_object_result_fails_loud_not_with_a_jq_crash() {
    # A top-level array is valid JSON but has no fields. Indexing it with a
    # string is a jq ERROR (exit 5), not a false — so the no-signal read must
    # not be the thing that hits it first. Assert the script's own fail-loud
    # contract holds: exit 2 with a `die` message, never a bare jq diagnostic.
    local rc=0 err
    command printf '[1,2,3]\n' >"$FIXTURES/array.json"
    err="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/array.json" \
        --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/array.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a non-object result exits 2, not jq's exit 5"
    assert_contains "$err" "review-convergence:" "it fails with the script's own message"
}

test_attempt_defaults_to_cycle_for_an_unmigrated_caller() {
    # A caller that has not adopted the two-counter split passes only --cycle.
    # The new rules must then be inert: with attempt defaulting to cycle, the C0
    # ceiling sits at 2x the cycle cap and never fires first.
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "the un-migrated caller still stops at its cap"
    assert_equals "C1-cap" "$(val rule "$out")" "C1 decides, not C0"
}

test_max_attempts_env_override_moves_the_ceiling() {
    # REVIEW_MAX_ATTEMPTS is the documented knob; pin that it is actually read.
    local out
    out="$(REVIEW_MAX_ATTEMPTS=6 "$RC" check --cycle 1 --max-cycles 5 --attempt 6 \
        --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)"
    assert_equals "C0-attempt-cap" "$(val rule "$out")" "the env ceiling is honored"
}
