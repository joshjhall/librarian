# shellcheck shell=bash
# Fail-loud exits (exit 2 + message on stderr) — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- Fail-loud exits (exit 2 + message on stderr) ---------------------------

test_bad_attempt_fails_loud() {
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --attempt 0 --result "$FIXTURES/zero.json" \
        --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --attempt 0 --result "$FIXTURES/zero.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--attempt 0 exits 2"
    assert_contains "$err" "--attempt must be an integer" "--attempt 0 fails loud"
}

test_noninteger_attempt_fails_loud() {
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --attempt 2x --result "$FIXTURES/zero.json" \
        --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --attempt 2x --result "$FIXTURES/zero.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a non-integer --attempt exits 2"
    assert_contains "$err" "--attempt must be an integer" "a non-integer --attempt fails loud"
}

test_bad_max_attempts_fails_loud() {
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --max-attempts 0 --result "$FIXTURES/zero.json" \
        --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --max-attempts 0 --result "$FIXTURES/zero.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--max-attempts 0 exits 2"
    assert_contains "$err" "--max-attempts must be an integer" "--max-attempts 0 fails loud"
}

test_max_attempts_below_max_cycles_fails_loud() {
    # A ceiling below the cycle cap makes C1 unreachable — every cycle cap would
    # silently become an attempt cap and the convergence policy would be
    # discarded. That is a misconfiguration, so it fails rather than clamping.
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --max-attempts 3 --result "$FIXTURES/zero.json" \
        --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --max-attempts 3 --result "$FIXTURES/zero.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--max-attempts below --max-cycles exits 2"
    assert_contains "$err" "cycle cap is unreachable" "it names the consequence, not just the values"
}

test_leading_zero_attempt_fails_loud() {
    # The octal guard, extended to the new flags: `08` crashes bash arithmetic
    # and `030` is silently read as octal.
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --attempt 08 --result "$FIXTURES/zero.json" \
        --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a leading-zero --attempt exits 2"
}

test_missing_cycle_fails_loud() {
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --cycle exits 2"
    assert_contains "$err" "needs --cycle" "missing --cycle fails loud on stderr"
}

test_missing_delta_lines_fails_loud() {
    # The most consequential omission: defaulted to 0 it would make every zero
    # look maximally narrow and silently route to C3, granting a free extra cycle
    # every time with no signal. It must fail, not default.
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --delta-lines exits 2 rather than defaulting"
    assert_contains "$err" "needs --delta-lines" "the message names the missing flag"
}

test_missing_max_cycles_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --max-cycles exits 2 (no implicit ceiling)"
}

test_missing_result_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --result exits 2"
}

test_zero_cycle_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 0 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--cycle 0 exits 2 (cycles are 1-based)"
}

test_zero_max_cycles_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 0 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--max-cycles 0 exits 2 (a cap of zero reviews nothing)"
}

test_negative_delta_lines_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines -5 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --delta-lines exits 2"
}

test_bad_partial_fails_loud() {
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 --partial yes >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--partial must be true|false, anything else exits 2"
}

test_unreadable_result_fails_loud() {
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/nope.json" --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/nope.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "an unreadable result file exits 2, never a verdict"
    assert_contains "$err" "cannot read result file" "the message names the unreadable file"
}

test_malformed_result_fails_loud() {
    local rc=0
    command printf 'not json at all' >"$FIXTURES/bad.json"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/bad.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "malformed result JSON exits 2 rather than reading as zero findings"
}

test_valid_json_scalar_is_not_misread_as_malformed() {
    # `jq empty` is the validity probe precisely because `jq -e .` reports a valid
    # `false`/`null` document as invalid — which would fail-loud a legitimate
    # cycle result.
    local out
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":null,"deferrable":[],"clean":false}' >"$FIXTURES/scalar.json"
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/scalar.json" \
        --delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "a null bucket is a valid empty cycle, not malformed JSON"
    # blocking_count()'s `// []` must coerce an explicit null the same way it
    # coerces an absent key (no-blocking-key.json covers that one) — a null here
    # would otherwise reach `[ "$blocking" -gt 0 ]` as the string "null" (#656).
    assert_equals "full" "$(val next_scope "$out")" \
        "an explicitly null blocking bucket reads as 0, not as the string null"
}

test_noninteger_line_start_fails_loud() {
    # #619: `.line_start` is interpolated into the fingerprint as a number, so it
    # never passes through the `field` encoder that guards `.file`/`.category`.
    # That asymmetry assumed FINDING_SCHEMA's integer constraint had already run —
    # but `read_findings` only checked that the document PARSES, and a result file
    # can reach this script without passing that gate. A string `line_start`
    # carrying a newline injects a second record and forges a C6 match through a
    # third field. The payload here is exactly that: the injected line is a
    # byte-exact copy of novel.json's fingerprint.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/evil.js","line_start":"0:x\\nsrc/a.js:10:correctness","category":"x","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/bad-line-start.json"
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/bad-line-start.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/bad-line-start.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a non-integer line_start exits 2 rather than injecting a record"
    assert_contains "$err" "line_start" "the message names the offending field"
}

test_fractional_line_start_fails_loud() {
    # The guard has TWO failure branches — not JSON type `number`, and a number
    # that is not whole — and the string fixture above only reaches the first.
    # A fractional `line_start` is a genuine JSON number, so it passes the type
    # check and can only be caught by the `floor` comparison. Verified by
    # mutation: deleting `and ((.line_start | floor) == .line_start)` leaves the
    # whole suite green without this case, i.e. half the guard was untested.
    #
    # It matters beyond tidiness because `10.5` and `10` are DISTINCT fingerprints
    # for what a well-formed producer would call the same line, so a fractional
    # value silently weakens C6 duplicate detection toward continue.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/f.js","line_start":10.5,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/frac-line-start.json"
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/frac-line-start.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/frac-line-start.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a fractional line_start exits 2 (the floor half of the guard)"
    assert_contains "$err" "line_start" "the message names the offending field"
}

test_null_line_start_is_valid() {
    # The complement, and the anti-tautology guard for the case above: a mutation
    # that rejected EVERY document would pass that test while breaking the script
    # entirely. `line_start` is legitimately omittable — `fingerprints` defaults it
    # via `// 0` — so an absent field must still produce a verdict, not an exit 2.
    command printf '{"issue":'"$T_ISSUE"',"run":"'"$T_RUN"'","blocking":[{"file":"src/z.js","category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/null-line-start.json"
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/null-line-start.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C8-novel" "$(val rule "$out")" "an omitted line_start still yields a verdict"
    assert_equals "1" "$(val findings "$out")" "the finding is counted, not rejected"
}

test_unreadable_prev_result_fails_loud() {
    # --prev-result goes through the same read_findings fail-loud path as
    # --result, but from inside a `while read` loop. Pin that the exit-2
    # propagates rather than being swallowed by the loop or its here-doc.
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/gone.json" --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/gone.json" --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "an unreadable --prev-result exits 2, not a verdict computed from partial history"
    assert_contains "$err" "cannot read result file" "the message names the unreadable prior-cycle file"
}

test_malformed_prev_result_fails_loud() {
    # The parent-shell guard has TWO branches (readable, then valid JSON). The
    # unreadable one is covered above; without this the jq-empty branch could be
    # dropped in a refactor and the suite would stay green.
    local rc=0 err
    command printf 'not json at all' >"$FIXTURES/bad-prev.json"
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/bad-prev.json" --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/bad-prev.json" --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a malformed --prev-result exits 2"
    assert_contains "$err" "not valid JSON" "the message names the malformed prior-cycle file"
}

test_unreadable_delta_files_is_silently_skipped() {
    # Deliberate asymmetry with --result/--prev-result: --delta-files is an
    # OPTIONAL enrichment for C7 only, so an absent one means "no recursive
    # signal available" and the other rules still decide. Failing loud here would
    # break cycle 1, which legitimately has no fix delta. Pinned so the asymmetry
    # is a documented decision rather than an unnoticed inconsistency.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/gone.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a missing --delta-files degrades to no recursive signal"
    assert_equals "0" "$(val recursive "$out")" "recursive stays 0 rather than failing the run"
}

test_bad_ratio_env_fails_loud() {
    local rc=0
    REVIEW_CONVERGENCE_SURFACE_RATIO=0 "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "RATIO out of 1-100 exits 2 (a bad override never picks a wrong boundary)"
}

test_leading_zero_numerics_fail_loud() {
    # Leading-zero digit strings feed bash arithmetic as OCTAL: 030 silently
    # applies a wrong threshold, 08/09 crash past the exit-2 contract. Same guard
    # class as workflow-wall-timeout.sh.
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 030 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --delta-lines (030) exits 2, not an octal comparison"
    rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 09 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --delta-lines with a 9 digit exits 2, does not crash"
    rc=0
    REVIEW_CONVERGENCE_SURFACE_RATIO=050 "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero RATIO (050) exits 2"
}

test_plain_zero_delta_lines_is_valid() {
    # `0` is the sole legitimate zero — an empty delta is a real state (a cycle
    # whose fix changed nothing), and the leading-zero rejection must not eat it.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 0 --prev-delta-lines 400 --partial false)"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "an empty delta is maximally narrow, and valid input"
}

test_prev_result_missing_its_value_fails_loud() {
    # `--prev-result --delta-lines 400` means the value was omitted. It must FAIL,
    # not be silently dropped: unlike the required single-value flags (whose
    # absence trips an explicit -z check), a dropped prior-cycle file is invisible
    # — the run would just see less history and drift toward novel/continue, a
    # verdict computed from silently-incomplete input.
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--prev-result with no value exits 2 rather than dropping the entry"
    assert_contains "$err" "needs a value" "the message says the flag needs a value"
}

test_prev_result_as_trailing_token_fails_loud() {
    # The BOUNDARY the mid-list test above misses. The `--*` guard only fires on
    # the iteration AFTER the flag, so it needs a following token to exist; a flag
    # that is the LAST argument falls off the end of the loop with an empty value
    # and no error. Same invisible drop, different route in.
    local rc=0 err
    err="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-result 2>&1 >/dev/null || true)"
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-result >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--prev-result as the last argument exits 2, not a silent empty"
    assert_contains "$err" "last argument" "the message names the trailing-flag case"
}

test_optional_flag_as_trailing_token_fails_loud() {
    # Same boundary in `opt`, and it matters MORE for the optional flags: an empty
    # --delta-files is indistinguishable from "not passed", so it silently
    # disables the C7 recursive signal rather than erroring.
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --delta-files >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--delta-files as the last argument exits 2"
}

test_optional_flag_missing_its_value_fails_loud() {
    # The mid-list half of the same guard for `opt`.
    local rc=0
    "$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-files --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--delta-files followed by a flag exits 2"
}

test_trailing_value_is_not_mistaken_for_a_missing_one() {
    # The complement, and the reason `opt` clears `_opt_prev` on its match: a
    # perfectly ordinary call whose FINAL token is a matched flag's own value must
    # still work. Without the reset, the trailing-flag check fires on every such
    # call — which is how this guard first broke every normal invocation.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --partial false --prev-delta-lines 400 --delta-lines 400)"
    assert_equals "continue" "$(val verdict "$out")" "a value in final position is a value, not a missing one"
    assert_equals "C8-novel" "$(val rule "$out")" "and the run proceeds normally"
}

test_duplicate_flag_is_first_match_wins() {
    # `opt` breaks on its first match, so a repeated flag's later occurrences are
    # never visited — including a dangling valueless one. The resolved value is
    # still correct (the first occurrence's), so this is deliberate, not a bug:
    # `opt_all` has no `break` because it must collect every occurrence, which is
    # why only IT needs the trailing guard to catch a dangling repeat. Pinned so
    # the asymmetry between the two parsers is a documented decision.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --delta-lines --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a duplicate flag resolves from the first occurrence"
    assert_equals "C8-novel" "$(val rule "$out")" "and the run proceeds on that value"
}

test_empty_string_value_behaves_as_absent() {
    # An explicit `--delta-files ''` is indistinguishable downstream from omitting
    # the flag (`-z` is true either way), so the C7 recursive signal degrades
    # silently. That is acceptable for an OPTIONAL enrichment — cycle 1 has no fix
    # delta at all — but the comments discussed it without pinning it. Now pinned.
    local out
    out="$("$RC" check --issue "$T_ISSUE" --run "$T_RUN" --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "an empty --delta-files degrades like an absent one"
    assert_equals "0" "$(val recursive "$out")" "no recursive signal, and no hard failure"
}

test_unknown_subcommand_fails_loud() {
    local rc=0
    "$RC" bogus >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "unknown subcommand exits 2"
}

test_no_subcommand_fails_loud() {
    local rc=0
    "$RC" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "no subcommand exits 2"
}
