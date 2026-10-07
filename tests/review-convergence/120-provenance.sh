# shellcheck shell=bash
# Result-file provenance (#1150, #1157) — review-convergence tests.
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

# stamped <name> <cycle-json> <issue-json> <blocking-json> [<run-json>] — write
# a result fixture carrying provenance. The provenance args are raw JSON so a
# case can pass `null`, a string, or omit nothing by accident. <run-json>
# defaults to this suite's run, "$T_RUN". Single-area helper, so it lives here
# rather than in the shared sandbox.
stamped() {
    command printf '{"cycle":%s,"issue":%s,"run":%s,"blocking":[%s],"deferrable":[]}\n' \
        "$2" "$3" "${5:-\"$T_RUN\"}" "$4" >"$FIXTURES/prov-$1.json"
    command printf '%s' "$FIXTURES/prov-$1.json"
}

# refused <label> <args...> — run check, assert exit 2, that no verdict was
# printed, AND that stderr carries the `refusal=provenance` marker the recipes
# key on (#1157): a refusal without it reads to the caller as a helper failure,
# and the documented fallback for that reads no provenance — fail-open.
# Leaves stderr in REFUSED_ERR for the caller's message assertions.
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
    # The FIRST line, exactly: a caller may read only that line, and the
    # header documents the marker as leading stderr.
    assert_equals "refusal=provenance" "${REFUSED_ERR%%
*}" "$label leads stderr with the refusal marker"
}

test_foreign_issue_result_is_refused_not_stopped() {
    # The #1145 replay: a ZERO-finding file left by another issue's run. Read
    # as-is it is a C4-zero stop; with --issue it must be a refusal instead.
    local f err
    f="$(stamped foreign-zero 1 999 "")"
    assert_equals "stop" "$(val verdict "$("$RC" check --cycle 1 --max-cycles 5 --issue 999 \
        --run "$T_RUN" --result "$f" --delta-lines 40)")" "precondition: for its own issue, the foreign zero reads as stop"
    refused "a foreign-issue --result" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$f" --delta-lines 40
    err="$REFUSED_ERR"
    assert_contains "$err" "has issue 999, not --issue 1150" "the message names both issues"
    assert_contains "$err" "re-extract" "the message says what to do"
}

test_result_without_issue_is_refused_when_issue_is_asserted() {
    local f err
    f="$(stamped no-issue 1 null "")"
    refused "an unstamped --result under --issue" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
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
    refused "a string-typed issue" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$f" --delta-lines 40
}

test_foreign_cycle_result_is_refused_with_matching_issue() {
    # Right issue, wrong cycle: the reused-filename-after-a-failed-write case.
    local f
    f="$(stamped same-issue-old-cycle 1 1150 "")"
    refused "a right-issue wrong-cycle --result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$f" --delta-lines 40
    assert_contains "$REFUSED_ERR" "is for cycle 1, not --cycle 2" "the message names both cycles"
}

test_foreign_prev_result_is_refused_on_a_zero_cycle() {
    # The CURRENT result is clean and correctly stamped, so the duplicate loop
    # (which only reads --prev-result when total > 0) would never open the
    # foreign file. The refusal must not depend on that loop.
    local cur prev err
    cur="$(stamped cur-zero 2 1150 "")"
    prev="$(stamped prev-foreign 1 999 "$(finding src/a.js 10 correctness R8-defect-in-new-code)")"
    refused "a foreign --prev-result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
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
    refused "a foreign second --prev-result" --cycle 3 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$good" --prev-result "$bad" --delta-lines 40
}

test_matching_provenance_yields_a_verdict() {
    # Positive control for every refusal above: same stamped shape, agreeing
    # values, and a prior cycle whose cycle number differs (as it must).
    local cur prev out rc=0
    cur="$(stamped ok-cur 2 1150 "$(finding src/c.js 30 correctness R8-defect-in-new-code)")"
    prev="$(stamped ok-prev 1 1150 "$(finding src/a.js 10 correctness R8-defect-in-new-code)")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" --result "$cur" \
        --prev-result "$prev" --delta-lines 40 --prev-delta-lines 40)" || rc=$?
    assert_exit "0" "$rc" "matching provenance exits 0"
    assert_equals "C8-novel" "$(val rule "$out")" "matching provenance reaches the rule list"
}

test_missing_issue_is_refused() {
    # #1157: --issue is REQUIRED. Opt-in, a caller that omitted it got only the
    # .cycle check and an unstamped file passed. The control is the same call
    # WITH the flag deciding (test_matching_provenance_yields_a_verdict).
    refused "check without --issue" --cycle 1 --max-cycles 5 --run "$T_RUN" \
        --result "$FIXTURES/zero.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "check needs --issue N" "the refusal names the missing flag"
}

test_missing_run_is_refused() {
    refused "check without --run" --cycle 1 --max-cycles 5 --issue "$T_ISSUE" \
        --result "$FIXTURES/zero.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "check needs --run ID" "the refusal names the missing flag"
    assert_contains "$REFUSED_ERR" "review-scratch.sh init/path --issue $T_ISSUE" \
        "the refusal says where the run id comes from"
}

test_foreign_run_result_is_refused() {
    # #1157's core case: same issue, same cycle, different run — a re-run of
    # the issue, or a re-attempt reusing the filename. issue + cycle agree, so
    # only the run nonce can tell the files apart.
    local f
    f="$(stamped other-run 1 1150 "" '"0123456789abcdef"')"
    refused "a same-issue same-cycle other-run --result" --cycle 1 --max-cycles 5 --issue 1150 \
        --run "$T_RUN" --result "$f" --delta-lines 40
    assert_contains "$REFUSED_ERR" "has run \"0123456789abcdef\", not --run $T_RUN" "the message names both runs"
    assert_contains "$REFUSED_ERR" "re-extract" "the message says what to do"
}

test_foreign_run_prev_result_is_refused_on_a_zero_cycle() {
    local cur prev
    cur="$(stamped cur-zero-otherrun 2 1150 "")"
    prev="$(stamped prev-otherrun 1 1150 "$(finding src/a.js 10 correctness R8-defect-in-new-code)" '"0123456789abcdef"')"
    refused "an other-run --prev-result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$prev" --delta-lines 40 --prev-delta-lines 40
    assert_contains "$REFUSED_ERR" "prior-cycle result" "the message says which file was foreign"
}

test_unstamped_run_is_refused() {
    # A null / absent run is a mismatch, and re-extracting cannot fix it — the
    # message must name the harness args instead (as for a null issue).
    local f g
    f="$(stamped null-run 1 1150 "" null)"
    refused "a null-run --result" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$f" --delta-lines 40
    assert_contains "$REFUSED_ERR" "has run null" "a null run is a mismatch, not a pass"
    assert_contains "$REFUSED_ERR" "re-run the harness with run: \"$T_RUN\"" \
        "a null run points at the harness args"
    g="$FIXTURES/prov-no-run-key.json"
    command printf '{"cycle":1,"issue":1150,"blocking":[],"deferrable":[]}\n' >"$g"
    refused "a --result with no run key" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$g" --delta-lines 40
}

test_non_string_run_does_not_match() {
    # tojson quotes a string: a numeric .run cannot equal a numeric-looking --run.
    local f
    f="$(stamped numeric-run 1 1150 "" 12345)"
    refused "a numeric .run" --cycle 1 --max-cycles 5 --issue 1150 --run 12345 \
        --result "$f" --delta-lines 40
}

test_bad_run_value_fails_loud() {
    local v
    # The third value is 65 characters: one past the cap.
    for v in 'a/b' 'a b' '{run}' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
        refused "--run '$v'" --cycle 1 --max-cycles 5 --issue 1150 --run "$v" \
            --result "$FIXTURES/zero.json" --delta-lines 40
        assert_contains "$REFUSED_ERR" "--run must" "--run '$v' names the flag"
    done
}

# arg_error <label> <args...> — a helper/usage failure unrelated to provenance:
# exit 2 with no verdict and NO `refusal=provenance` marker, so the recipes'
# fallback stays reachable when the helper genuinely cannot decide (#1157).
# ARG_ENV, when set, is a PATH value to run the helper under (the no-jq case).
ARG_ENV=""
arg_error() {
    local label="$1" rc=0 out errf
    shift
    errf="$(command mktemp)"
    if [ -n "$ARG_ENV" ]; then
        out="$(command env BASH_ENV= PATH="$ARG_ENV" "$BASH" "$RC" check "$@" 2>"$errf")" || rc=$?
    else
        out="$("$RC" check "$@" 2>"$errf")" || rc=$?
    fi
    REFUSED_ERR="$(command cat "$errf")"
    command rm -f "$errf"
    assert_exit "2" "$rc" "$label exits 2"
    assert_not_contains "$out" "verdict=" "$label emits no verdict on stdout"
    assert_not_contains "$REFUSED_ERR" "refusal=provenance" "$label is not marked a provenance refusal"
}

test_bad_issue_value_fails_loud() {
    local v err
    # A malformed provenance flag IS a refusal (#1157 review c4): most likely an
    # unsubstituted placeholder, and falling back would skip provenance.
    for v in 0 07 x -3 '{N}'; do
        refused "--issue '$v'" --cycle 1 --max-cycles 5 --issue "$v" --run "$T_RUN" \
            --result "$FIXTURES/zero.json" --delta-lines 40
        err="$REFUSED_ERR"
        assert_contains "$err" "--issue must be an integer >= 1" "--issue '$v' names the flag"
    done
}

test_valueless_provenance_flag_is_refused() {
    # `--run $RUN` with RUN empty yields a bare trailing `--run`; `--issue $N`
    # with N empty yields `--issue --run X`. Both must be REFUSALS, not the
    # unmarked usage error `opt` gives every other flag (#1157 review c5).
    refused "a trailing valueless --run" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --issue 1150 --run
    assert_contains "$REFUSED_ERR" "--run needs a value but was the last argument" "names the trailing flag"
    refused "a trailing valueless --issue" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --run "$T_RUN" --issue
    refused "--issue followed by a flag" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --issue --run "$T_RUN"
    assert_contains "$REFUSED_ERR" "--issue needs a value, got the flag '--run'" "names the swallowed flag"
    refused "--run followed by a flag" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --issue 1150 --run --delta-lines 40
    # A QUOTED empty expansion (`--run "$RUN"`, RUN unset) is a present-but-
    # empty value: the required-flag check, not the pre-scan, refuses it.
    refused "an explicitly empty --run" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --issue 1150 --run ''
    refused "an explicitly empty --issue" --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --issue '' --run "$T_RUN"
}

test_boundary_valid_run_is_accepted() {
    # Positive side of the cap: 64 chars including . _ - is accepted and
    # decides (an off-by-one tightening to 63 must fail here).
    local id f out rc=0
    id='a.b_c-0123456789012345678901234567890123456789012345678901234567'
    assert_equals "64" "${#id}" "precondition: the boundary id is 64 chars"
    f="$(stamped run64 1 1150 "" "\"$id\"")"
    out="$("$RC" check --cycle 1 --max-cycles 5 --issue 1150 --run "$id" --result "$f" --delta-lines 40)" || rc=$?
    assert_exit "0" "$rc" "a 64-char run with . _ - is accepted"
    assert_equals "C4-zero" "$(val rule "$out")" "the boundary run reaches the rule list"
}

test_unusable_current_result_is_refused() {
    # --result's own readability/JSON refusals (previously pinned only for
    # --prev-result): deciding without this cycle's file is the #1145 shape.
    command printf 'not json\n' >"$FIXTURES/prov-cur-invalid.json"
    refused "a missing --result" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/prov-cur-absent.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "cannot read result file" "a missing --result names the read failure"
    refused "an invalid-JSON --result" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/prov-cur-invalid.json" --delta-lines 40
}

test_helper_failures_carry_no_refusal_marker() {
    # The negative half of the contract: an ordinary usage error is NOT a
    # refusal, or the documented fallback for a broken helper is unreachable.
    arg_error "a bad --cycle" --cycle 0 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/zero.json" --delta-lines 40
    arg_error "a missing --delta-lines" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/zero.json"
    # No jq: the "helper cannot run" case the fallback exists for. PATH holds
    # only a dir with the coreutils the script needs, and no jq.
    local bin="$FIXTURES/nojq-bin" t
    command mkdir -p "$bin"
    for t in cat grep sed awk tr mktemp rm; do
        if command -v "$t" >/dev/null 2>&1; then
            command ln -sf "$(command -v "$t")" "$bin/$t"
        fi
    done
    ARG_ENV="$bin"
    arg_error "a missing jq" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/zero.json" --delta-lines 40
    ARG_ENV=""
    assert_contains "$REFUSED_ERR" "jq is required" "the no-jq failure names jq"
}

test_string_cycle_does_not_match_the_number() {
    # The cycle twin of the string-issue case: "1" is not the integer 1.
    local f
    f="$(stamped string-cycle '"1"' 1150 "")"
    refused "a string-typed cycle" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
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
    refused "a missing --prev-result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$FIXTURES/prov-does-not-exist.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "cannot read result file" "a missing --prev-result names the read failure"
    refused "an invalid-JSON --prev-result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$FIXTURES/prov-invalid.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "is not valid JSON" "an invalid --prev-result names the parse failure"
    refused "an array --prev-result" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$FIXTURES/prov-array.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "has issue null" "a non-object --prev-result reads as unstamped, not a jq crash"
}

test_unstamped_prev_result_is_refused_under_issue() {
    # The prev role's null-stamp branch: a prior file with `issue: null` must be
    # refused with the prior-cycle wording, not accepted as "no stamp, no check".
    local cur prev
    cur="$(stamped cur-zero-nullprev 2 1150 "")"
    prev="$(stamped prev-null 1 null "")"
    refused "an unstamped --prev-result under --issue" --cycle 2 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$cur" --prev-result "$prev" --delta-lines 40
    assert_contains "$REFUSED_ERR" "prior-cycle result" "the null prev names its role"
    assert_contains "$REFUSED_ERR" "has issue null" "the null prev names the missing stamp"
}

test_non_object_result_is_refused_under_issue() {
    # The `result` role's half of the type guard: an array --result reads as
    # unstamped and is refused with a provenance message, not a bare jq crash.
    command printf '[1,2]\n' >"$FIXTURES/prov-array-result.json"
    refused "an array --result under --issue" --cycle 1 --max-cycles 5 --issue 1150 --run "$T_RUN" \
        --result "$FIXTURES/prov-array-result.json" --delta-lines 40
    assert_contains "$REFUSED_ERR" "result file" "the array result names its role"
    assert_contains "$REFUSED_ERR" "has issue null" "the array result reads as unstamped"
}

test_null_cycle_result_is_accepted() {
    # The documented pre-stamp case: an explicit `"cycle": null` skips the
    # cycle check (only a PRESENT cycle can disagree) and reaches a verdict.
    local f out rc=0
    f="$(stamped null-cycle null 1150 "")"
    out="$("$RC" check --cycle 3 --max-cycles 5 --issue 1150 --run "$T_RUN" --result "$f" --delta-lines 40)" || rc=$?
    assert_exit "0" "$rc" "a null cycle stamp is not a mismatch"
    assert_equals "C4-zero" "$(val rule "$out")" "a null cycle stamp reaches the rule list"
}

# recipe_check_invocations — print each `review-convergence.sh check` command
# found inside a fenced block of a plugins/**/*.md file, joined across its `\`
# continuation lines, one invocation per output line prefixed `path:line:`.
# Prose mentions (outside a fence) are not commands and are skipped.
recipe_check_invocations() {
    local f
    command find "$REPO_ROOT/plugins" -name '*.md' -type f | command sort | while IFS= read -r f; do
        command awk -v path="${f#"$REPO_ROOT"/}" '
            /^[[:space:]]*```/ { fence = !fence; next }
            fence {
                # A line ending in `\` continues. Strip the marker before
                # joining, or a valueless `--issue \` reads the `\` as its value.
                line = $0
                more = sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
                if (cmd == "" && line ~ /review-convergence\.sh check/) { cmd = line; start = NR }
                else if (cmd != "") { cmd = cmd " " line }
                if (cmd != "" && !more) { print path ":" start ":" cmd " "; cmd = "" }
            }
        ' "$f"
    done
}

test_recipes_key_the_refusal_exception_on_the_marker() {
    # The fallback-vs-refusal split lives in prose an agent applies. If a recipe
    # keyed its exception on message wording again, any refusal whose message
    # lacked that phrase would fall back fail-open — which is what #1157 cycle 3
    # found for every run and required-flag refusal. Pin the marker at both
    # exception paragraphs, and that neither keys on the old phrase.
    # Whitespace-normalized: the old trigger was line-wrapped in one recipe, so
    # a raw single-line needle could never match it there (#1157 review c4).
    local f body
    for f in adversarial-review-step.md ci-review-protocol.md; do
        body="$(command tr '\n' ' ' <"$REPO_ROOT/plugins/workflow/skills/ship-issue/$f" | command tr -s ' ')"
        assert_contains "$body" 'stderr line `refusal=provenance`' "$f keys the exception on the marker"
        assert_not_contains "$body" 'with `a stale or foreign result file`' "$f no longer keys on message prose"
    done
}

test_every_shipped_recipe_passes_issue() {
    # Both flags are required (#1157), so a recipe that drops one now dies at
    # runtime instead of going inert — but only when a review loop runs. Pin it
    # at the call sites themselves so the break shows up here first.
    local inv n=0 missing=""
    while IFS= read -r inv; do
        [ -n "$inv" ] || continue
        n=$((n + 1))
        # `--issue` must carry a value: a bare trailing `--issue` would pass a
        # substring match yet die at runtime ("needs a value").
        if ! command printf '%s\n' "$inv" | command grep -E ' --issue [^[:space:]-]' >/dev/null ||
            ! command printf '%s\n' "$inv" | command grep -E ' --run [^[:space:]-]' >/dev/null; then
            missing="$missing ${inv%%:<*}" # path:line only
        fi
    done <<EOF
$(recipe_check_invocations)
EOF
    # Vacuity floor: the two shipped review loops. Zero would mean the parser,
    # not the recipes, is broken — and would pass every per-call check.
    assert_true "[ $n -ge 2 ]" "found every recipe invocation of check (got $n, want >= 2)"
    assert_equals "" "$missing" "every recipe invocation of check passes --issue and --run"
}
