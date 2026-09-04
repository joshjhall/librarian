#!/usr/bin/env bash
# run-all.sh end-of-run verdict reporting (issue #854).
#
# WHAT THIS EXISTS TO STOP. `bash tests/run-all.sh | tail -45` reports **exit 0
# on a red suite**. A pipeline's status is its LAST command's, so the caller
# reads `tail`'s success; and the `One or more test stages FAILED` banner was
# written to stdout — the very stream the pipe consumed. Green when red, which
# is the direction an agent or script acts on before committing. Observed live:
# a run whose `Markdown lint (.claude/memory/)` stage failed reported 0 through
# `| tail` and 1 when redirected to a file, costing a ~9-minute re-run.
#
# run-all.sh cannot fix its caller's pipeline status — `set -o pipefail` is a
# property of the INVOKING shell. What it can do is make the failure impossible
# to lose, which is the contract this gate pins:
#
#   1. a failing run writes its verdict to **stderr** as well as stdout, so it
#      survives a stdout-only pipe;
#   2. that verdict names the stages that FAILED, printed LAST so a truncating
#      reader (`| tail -N`) keeps them;
#   3. a PASSING run writes **nothing** to stderr — a mirror that also announced
#      success would train every caller to ignore the stream, costing exactly
#      the signal it was added for. Both directions, or this is not a gate.
#
# WHY IT SLICES INSTEAD OF RUNNING THE SUITE. run-all.sh is a linear script that
# executes ~100 stages over ~9 minutes; sourcing it would run the whole thing.
# So `run_stage`, `print_summary` and `emit_summary` are sliced out of the source
# and eval'd in isolation over synthetic stages — the same "slice the pure
# helper" idiom tests/validate-lint-gates.sh uses for run_stage (and
# validate-workflow-helpers.mjs on the node side). The helpers under test are the REAL ones, read from
# disk at run time, so this cannot drift from the file it validates.
#
# Pure bash + coreutils; no network. bash-3.2 clean, no GNU-only regex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ALL="$SCRIPT_DIR/run-all.sh"
REAL_BASH="$(command -v bash)"

# The reserved "did not run" sentinel. Duplicated from the script under test on
# purpose: importing it would make the assertion tautological.
SKIP_SENTINEL=77

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "run-all.sh verdict reporting (pipe-safe failure) (#854)"

# --- Fixture -----------------------------------------------------------------
#
# run_mini_suite <stream> <exit-code>... — build a miniature suite from the REAL
# run_stage + print_summary, with one synthetic stage per exit code given, and
# echo the requested stream.
#
# <stream> selects what the caller sees, which is the whole point of the fixture:
#   stdout — 2>/dev/null, i.e. what a `| tail` reader keeps
#   stderr — 2>&1 >/dev/null, i.e. what SURVIVES a stdout-only pipe
#   both   — 2>&1, plus a trailing SUITE_RC= line
#
# Stage N is labelled "Stage N (<code>)" so an assertion can pin that the FAILED
# stage's own name reached the summary, not merely that some banner printed.
run_mini_suite() {
    local stream="$1"
    shift
    local script='
        set -uo pipefail
        rc=0
        failed_stages=""
        SKIP_EXIT_CODE=77
        eval "$(command sed -n "/^run_stage() {/,/^}/p" "$RUN_ALL_PATH")"
        eval "$(command sed -n "/^print_summary() {/,/^}/p" "$RUN_ALL_PATH")"
        eval "$(command sed -n "/^emit_summary() {/,/^}/p" "$RUN_ALL_PATH")"
        n=0
        for code in $CODES; do
            n=$((n + 1))
            run_stage "Stage $n ($code)" "$MINI_BASH" -c "exit $code"
        done
        emit_summary
        printf "SUITE_RC=%s\n" "$rc"
    '
    local out
    case "$stream" in
        stdout)
            out="$(RUN_ALL_PATH="$RUN_ALL" MINI_BASH="$REAL_BASH" CODES="$*" \
                /usr/bin/env --unset=BASH_ENV "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" -c "$script" 2>/dev/null)"
            ;;
        stderr)
            out="$(RUN_ALL_PATH="$RUN_ALL" MINI_BASH="$REAL_BASH" CODES="$*" \
                /usr/bin/env --unset=BASH_ENV "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" -c "$script" 2>&1 >/dev/null)"
            ;;
        *)
            out="$(RUN_ALL_PATH="$RUN_ALL" MINI_BASH="$REAL_BASH" CODES="$*" \
                /usr/bin/env --unset=BASH_ENV "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" -c "$script" 2>&1)"
            ;;
    esac
    printf '%s\n' "$out"
}

# --- The reported bug: a failure survives a stdout-only pipe ------------------

test_failure_reaches_stderr() {
    local err
    err="$(run_mini_suite stderr 0 1 0)"

    assert_contains "$err" "One or more test stages FAILED" \
        "the FAILED verdict reaches stderr, which a stdout pipe cannot swallow"
}

# The complement, and the reason the assertion above has teeth: the SAME run's
# stdout is what `| tail` keeps, so if the verdict were only there the pipe would
# eat it. Pinning both streams is what distinguishes "mirrored" from "moved".
test_failure_still_on_stdout() {
    local out
    out="$(run_mini_suite stdout 0 1 0)"

    assert_contains "$out" "One or more test stages FAILED" \
        "the FAILED verdict is still on stdout too (mirrored, not moved)"
    # The banner alone is not the verdict. Asserting the stage LIST on both
    # streams is what catches a regression that dropped it from the stdout copy
    # while leaving stderr intact — an asymmetry a banner-only check cannot see.
    assert_contains "$out" "  [FAIL] Stage 2 (1)" \
        "the failed-stage LIST is on stdout too, not only on stderr"
}

test_stderr_names_the_failed_stage() {
    local err
    err="$(run_mini_suite stderr 0 1 0)"

    assert_contains "$err" "  [FAIL] Stage 2 (1)" \
        "the stderr verdict names the stage that FAILED"
    assert_not_contains "$err" "Stage 1 (0)" \
        "a PASSING stage is not listed as failed"
}

# A reader who keeps only the tail must keep the stage list. Pinning the ORDER
# (list after banner) is the property, not merely that both strings appear.
test_failed_stage_list_comes_last() {
    local err banner_line list_line
    err="$(run_mini_suite stderr 1)"
    banner_line="$(printf '%s\n' "$err" | command grep -n 'test stages FAILED' | head -1 | cut -d: -f1)"
    list_line="$(printf '%s\n' "$err" | command grep -n '^  \[FAIL\] Stage 1' | head -1 | cut -d: -f1)"

    assert_true "[ -n '$banner_line' ] && [ -n '$list_line' ] && [ '$list_line' -gt '$banner_line' ]" \
        "the failed-stage list prints AFTER the banner, so | tail keeps it"
}

# The accumulator is new logic, and every case above drives exactly ONE failing
# stage — which is precisely the input a concatenation bug survives. Two failures
# is the smallest fixture where a stray newline could join two labels into one
# line, or the order could come out reversed.
test_multiple_failed_stages_all_listed() {
    local err first_line second_line
    err="$(run_mini_suite stderr 0 1 1 0)"

    assert_contains "$err" "  [FAIL] Stage 2 (1)" "the first failed stage is listed"
    assert_contains "$err" "  [FAIL] Stage 3 (1)" "the second failed stage is listed"
    assert_not_contains "$err" "[FAIL] Stage 1 (0)" "a passing stage is still not listed"

    # Order, and that they are separate LINES — a lost newline would render
    # "Stage 2 (1)Stage 3 (1)" on one line, which both assertions above survive.
    first_line="$(printf '%s\n' "$err" | command grep -n '^  \[FAIL\] Stage 2' | head -1 | cut -d: -f1)"
    second_line="$(printf '%s\n' "$err" | command grep -n '^  \[FAIL\] Stage 3' | head -1 | cut -d: -f1)"
    assert_true "[ -n '$first_line' ] && [ -n '$second_line' ] && [ '$second_line' -gt '$first_line' ]" \
        "the two failed stages are on separate lines, in run order"
}

# --- The negative arm: a green run must not cry wolf on stderr ---------------

test_passing_run_is_silent_on_stderr() {
    local err
    err="$(run_mini_suite stderr 0 0)"

    assert_true "[ -z \"\$(printf '%s' \"$err\" | command tr -d '[:space:]')\" ]" \
        "a passing suite writes NOTHING to stderr"
}

test_passing_run_still_reports_success_on_stdout() {
    local out
    out="$(run_mini_suite stdout 0 0)"

    assert_contains "$out" "All test stages passed" \
        "a passing suite still prints its success banner on stdout"
    assert_contains "$out" "SUITE_RC=0" "a passing suite exits 0"
}

# --- The exit code itself, and the capture recipe that preserves it ----------

test_failing_suite_rc_is_nonzero() {
    local both
    both="$(run_mini_suite both 0 1)"

    assert_contains "$both" "SUITE_RC=1" \
        "a failed stage still fails the suite (the rc a pipe would discard)"
}

# The fix is two-part — loudness AND a documented invocation. The verdict itself
# carries the second half, so a reader who hit the bug is told how to avoid it
# without having to find the docs.
test_verdict_states_the_capture_recipe() {
    local err
    err="$(run_mini_suite stderr 1)"

    assert_contains "$err" "> /tmp/run.log 2>&1" \
        "the failure verdict states the capture-not-pipe recipe"
}

# --- Guard the sentinel behaviour this change had to preserve (#538) ---------
#
# print_summary now reads a list run_stage populates, so the [FAIL] branch was
# touched. A 77 stage must still not enter that list nor fail the suite — the
# neighbouring arm is exactly where a change like this breaks something.

test_skip_stage_is_not_reported_as_failed() {
    local both
    both="$(run_mini_suite both 0 "$SKIP_SENTINEL")"

    assert_contains "$both" "SUITE_RC=0" "a skipped stage leaves the suite rc at 0"
    assert_contains "$both" "All test stages passed" \
        "a skipped stage does not trigger the FAILED verdict"
    assert_not_contains "$both" "  [FAIL] Stage 2" \
        "a skipped stage is not listed among the failed stages"
}

# --- Wiring: the docs carry the same recipe ----------------------------------
#
# AC1 is about a READER of the documented invocation, so the documented
# invocation has to actually say it. Anchored on the recipe's own text, which is
# the thing that must not silently disappear.

test_docs_carry_the_capture_recipe() {
    assert_file_contains "$SCRIPT_DIR/../CLAUDE.md" "run.log 2>&1" \
        "CLAUDE.md documents capturing the suite rather than piping it"
    assert_file_contains "$SCRIPT_DIR/README.md" "run.log 2>&1" \
        "tests/README.md documents capturing the suite rather than piping it"
}

run_test test_failure_reaches_stderr "a failing verdict reaches stderr (survives | tail)"
run_test test_failure_still_on_stdout "the failing verdict is mirrored, not moved off stdout"
run_test test_stderr_names_the_failed_stage "the stderr verdict names the failed stage"
run_test test_failed_stage_list_comes_last "the failed-stage list prints after the banner"
run_test test_multiple_failed_stages_all_listed "every failed stage is listed, in order, on its own line"
run_test test_passing_run_is_silent_on_stderr "a passing suite is silent on stderr"
run_test test_passing_run_still_reports_success_on_stdout "a passing suite still reports success on stdout"
run_test test_failing_suite_rc_is_nonzero "a failed stage still fails the suite"
run_test test_verdict_states_the_capture_recipe "the verdict states the capture-not-pipe recipe"
run_test test_skip_stage_is_not_reported_as_failed "a 77 skip is neither failed nor silent (#538)"
run_test test_docs_carry_the_capture_recipe "the docs carry the same capture recipe"

generate_report
