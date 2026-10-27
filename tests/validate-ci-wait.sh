#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/ci-wait.sh (issue #1244).
#
# ci-wait.sh is the CI-wait poll loop moved out of prose and into one plain
# command, so a worktree-isolated session can run it (the hand-written loop
# needs a `$(…)` the isolation refuses) WITHOUT falling back to an unbounded
# `gh pr checks --watch`. What a regression here would cost is exactly what #1244
# was filed against: a wait with no ceiling, or a CI state misread as green.
#
# So this gate pins four things:
#   1. the state reduction — fail beats pending, cancel is a fail, and an EMPTY
#      check list is pending (never a pass);
#   2. the bound — a never-finishing CI run reaches `stop` (exit 9), L3-L4
#      extensions are carried between polls, L1-L2 exits at the checkpoint;
#   3. delegation — the verdict comes from ci-wait-timeout.sh, not a private
#      copy of its arithmetic (a poisoned env var must surface through it);
#   4. fail-loud — a gh error or a hung gh is exit 3, never a pass.
#
# `gh`, `date` and `sleep` are stubbed on PATH. The `date` stub advances a
# file-backed clock 5 minutes per call, so a 45-minute ceiling is crossed in a
# handful of polls and the suite never actually waits. The `sleep` stub is a
# no-op EXCEPT for bounded-run's watcher, which needs a real sleep to bound the
# hung-gh case — so it delegates to the real binary for anything but our poll
# interval (marked with the sentinel value 0).
#
# Pure bash + coreutils. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CW="$REPO_ROOT/plugins/workflow/scripts/ci-wait.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "ci-wait.sh (#1244)"

SB="$(command mktemp -d)"
trap 'command rm -rf "$SB"' EXIT
STUB_BIN="$SB/bin"
command mkdir -p "$STUB_BIN"
REAL_SLEEP="$(command -v sleep)"

# gh stub: answers each `gh pr checks` call with the next line of $SB/states
# (the last line repeats forever). A line is a JSON check array, or one of the
# control words `ERROR` (exit 1) / `HANG` (never answers). The array is run
# through the SCRIPT'S OWN `--jq` expression with a real jq — an earlier draft
# reduced the arrays in the stub itself, and mutation testing showed the
# reduction under test was then never exercised (flip "empty -> pending" to
# "pass" and every case stayed green). Exit codes mirror gh: 8 when the reduced
# state is pending, 1 when it is fail. Every call is logged so a test can count
# polls.
command cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
sb="${CIW_SB:?}"
echo "call $1 $2 $3" >>"$sb/gh.log" # one line per call; the --jq arg is multi-line
expr=""
prev=""
for a in "$@"; do
    [ "$prev" = "--jq" ] && expr="$a"
    prev="$a"
done
n="$(wc -l <"$sb/gh.log")"; n=$((n))
total="$(wc -l <"$sb/states")"; total=$((total))
[ "$n" -le "$total" ] || n="$total"
line="$(sed -n "${n}p" "$sb/states")"
case "$line" in
    ERROR) echo "HTTP 502: bad gateway" >&2; exit 1 ;;
    HANG) exec sleep 600 ;;
esac
out="$(printf '%s' "$line" | jq -r "$expr")" || exit 4
echo "$out"
case "$out" in
    pending) exit 8 ;;
    fail) exit 1 ;;
esac
STUB

# date stub: `date +%s` returns a clock that advances 300 s per call.
command cat >"$STUB_BIN/date" <<'STUB'
#!/usr/bin/env bash
sb="${CIW_SB:?}"
t="$(cat "$sb/clock" 2>/dev/null || echo 1000000)"
echo "$t"
echo $((t + 300)) >"$sb/clock"
STUB

# sleep stub: the poll interval (0 in these tests) returns at once; anything
# else (bounded-run's watcher) gets the real sleep so the bound still fires.
command cat >"$STUB_BIN/sleep" <<STUB
#!/usr/bin/env bash
[ "\$1" = "0" ] && exit 0
exec "$REAL_SLEEP" "\$@"
STUB
command chmod +x "$STUB_BIN/gh" "$STUB_BIN/date" "$STUB_BIN/sleep"

# reset <state-line>... — fresh gh log, clock, and scripted state sequence.
reset() {
    command rm -f "$SB/gh.log" "$SB/clock"
    : >"$SB/gh.log"
    command printf '%s\n' "$@" >"$SB/states"
}

# cw_env [VAR=val]... <cmd>... — run under the stubs. -uBASH_ENV is
# load-bearing: in the devcontainer BASH_ENV sources a profile that rebuilds
# PATH, which silently drops $STUB_BIN and lets the REAL gh answer — every case
# then reads a live PR (same reason as tests/lib/golem-sandbox.sh).
cw_env() {
    command env -uBASH_ENV CIW_SB="$SB" PATH="$STUB_BIN:$PATH" "$@"
}

# run_cw <args>... — run the waiter under the stubs; sets OUT and RC.
OUT=""
RC=0
run_cw() {
    RC=0
    OUT="$(cw_env "$CW" "$@" --interval 0 2>&1)" || RC=$?
}

val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

polls() {
    command wc -l <"$SB/gh.log" | command tr -d ' '
}

# --- 1. State reduction --------------------------------------------------------
# Every case that feeds the stub a check array needs jq, because the stub applies
# the script's own reduction with it. Without jq they skip VISIBLY, never pass.
need_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    skip_test "jq not installed — the gh stub cannot apply ci-wait.sh's --jq"
    return 1
}

test_all_pass_exits_0() {
    need_jq || return 0
    reset '[{"bucket":"pass"},{"bucket":"skipping"}]'
    run_cw 7 --level 3
    assert_exit 0 "$RC" "all checks passed -> exit 0"
    assert_equals "pass" "$(val result "$OUT")" "result=pass"
    assert_equals "1" "$(polls)" "a resolved state needs one poll"
}

test_fail_exits_1() {
    need_jq || return 0
    reset '[{"bucket":"pass"},{"bucket":"fail"}]'
    run_cw 7 --level 3
    assert_exit 1 "$RC" "a failed check -> exit 1 (triage), not a pass"
    assert_equals "fail" "$(val result "$OUT")" "result=fail"
}

test_cancel_is_a_fail() {
    need_jq || return 0
    reset '[{"bucket":"pass"},{"bucket":"cancel"}]'
    run_cw 7 --level 3
    assert_exit 1 "$RC" "a cancelled check is a failure, never a pass"
}

test_fail_beats_pending() {
    need_jq || return 0
    reset '[{"bucket":"pending"},{"bucket":"fail"}]'
    run_cw 7 --level 3
    assert_exit 1 "$RC" "a red check is final even while others are pending"
}

test_pending_then_pass() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]' '[{"bucket":"pending"}]' '[{"bucket":"pass"}]'
    run_cw 7 --level 3
    assert_exit 0 "$RC" "pending resolves to pass -> exit 0"
    assert_equals "3" "$(polls)" "the waiter kept polling until CI resolved"
}

test_empty_check_list_is_pending_not_pass() {
    need_jq || return 0
    reset '[]' '[{"bucket":"pass"}]'
    run_cw 7 --level 3
    assert_exit 0 "$RC" "eventually passes once checks register"
    assert_equals "2" "$(polls)" "an empty check list was NOT read as green on poll 1"
}

# --- 2. The bound -----------------------------------------------------------------

test_stuck_ci_stops_at_ceiling() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    run_cw 7 --level 4
    assert_exit 9 "$RC" "never-finishing CI -> stop, exit 9"
    assert_equals "pending" "$(val result "$OUT")" "result=pending at the stop"
    assert_equals "stop" "$(val verdict "$OUT")" "verdict=stop"
    assert_equals "45" "$(val ceiling_min "$OUT")" "default ceiling is 45 min"
    assert_equals "2" "$(val extensions_used "$OUT")" "both L4 extensions were carried forward"
    assert_true "[ $(polls) -le 12 ]" "stops at the ceiling (~10 polls of 5 min), not by running away"
}

test_timeout_env_moves_the_ceiling() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    RC=0
    OUT="$(cw_env LIBRARIAN_CI_WAIT_TIMEOUT=5 \
        LIBRARIAN_CI_WAIT_MAX_EXTENSIONS=0 "$CW" 7 --level 3 --interval 0 2>&1)" || RC=$?
    assert_exit 9 "$RC" "a 5-min, no-extension budget stops"
    assert_equals "5" "$(val ceiling_min "$OUT")" "the env override reached the bound"
    # The stub clock reads 5 min at the first poll (start costs one tick), so
    # the first pending answer is already at the 5-min ceiling.
    assert_equals "1" "$(polls)" "stopped on the first poll that reached 5 min"
}

test_l2_exits_at_checkpoint() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    run_cw 7 --level 2
    assert_exit 8 "$RC" "L1-L2 crossing the checkpoint -> exit 8 for the human"
    assert_equals "checkpoint" "$(val verdict "$OUT")" "verdict=checkpoint"
    assert_equals "0" "$(val extensions_used "$OUT")" "an L2 wait never auto-extends"
}

test_resume_after_checkpoint_extend() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    run_cw 7 --level 2 --elapsed-min 15 --extensions-used 1
    assert_exit 8 "$RC" "the resumed wait reaches the next checkpoint"
    assert_equals "1" "$(val extensions_used "$OUT")" "the granted extension was honoured"
    assert_true "[ $(val elapsed_min "$OUT") -ge 30 ]" "carried minutes count toward the next checkpoint"
}

test_resumed_elapsed_counts_toward_ceiling() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    run_cw 7 --level 4 --elapsed-min 44 --extensions-used 2
    assert_exit 9 "$RC" "44 carried minutes + one poll crosses the 45-min ceiling"
    assert_equals "1" "$(polls)" "stopped on poll 1 — the carried time was not discarded"
}

# --- 3. Delegation ------------------------------------------------------------------

test_verdict_comes_from_the_timeout_helper() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    RC=0
    OUT="$(cw_env LIBRARIAN_CI_WAIT_TIMEOUT=abc \
        "$CW" 7 --level 3 --interval 0 2>&1)" || RC=$?
    assert_exit 2 "$RC" "a bad env var surfaces through ci-wait-timeout.sh as exit 2"
    assert_contains "$OUT" "LIBRARIAN_CI_WAIT_TIMEOUT" "the helper's own diagnostic is relayed"
}

test_bad_level_fails_loud_via_helper() {
    need_jq || return 0
    reset '[{"bucket":"pending"}]'
    run_cw 7 --level 9
    assert_exit 2 "$RC" "--level 9 is refused by the helper that owns the rule"
}

# --- 4. Fail loud ---------------------------------------------------------------------

test_gh_error_is_exit_3_not_pass() {
    reset 'ERROR'
    run_cw 7 --level 3
    assert_exit 3 "$RC" "a gh failure -> exit 3, never a pass"
    assert_contains "$OUT" "bad gateway" "gh's own error is relayed"
    assert_not_contains "$OUT" "result=pass" "no pass is printed on a gh error"
}

test_hung_gh_is_bounded() {
    reset 'HANG'
    RC=0
    OUT="$(cw_env LIBRARIAN_CI_WAIT_POLL_TIMEOUT=1 \
        "$CW" 7 --level 3 --interval 0 2>&1)" || RC=$?
    assert_exit 3 "$RC" "a gh call that never answers is bounded -> exit 3"
    assert_contains "$OUT" "did not answer" "the timeout is named"
}

test_usage_errors() {
    reset '[{"bucket":"pass"}]'
    run_cw --level 3
    assert_exit 2 "$RC" "missing PR -> exit 2"
    run_cw 7
    assert_exit 2 "$RC" "missing --level -> exit 2"
    run_cw abc --level 3
    assert_exit 2 "$RC" "non-numeric PR -> exit 2"
    run_cw 7 --level 3 --elapsed-min -1
    assert_exit 2 "$RC" "negative --elapsed-min -> exit 2"
    run_cw 7 --level 3 --bogus
    assert_exit 2 "$RC" "unknown flag -> exit 2"
    assert_equals "0" "$(polls)" "no usage error ever reached gh"
}

test_bad_poll_timeout_env_fails_loud() {
    reset '[{"bucket":"pass"}]'
    RC=0
    OUT="$(cw_env LIBRARIAN_CI_WAIT_POLL_TIMEOUT=0 \
        "$CW" 7 --level 3 --interval 0 2>&1)" || RC=$?
    assert_exit 2 "$RC" "a zero poll timeout is refused, not run unbounded"
}

run_test test_all_pass_exits_0 "all checks pass -> exit 0"
run_test test_fail_exits_1 "a failed check -> exit 1"
run_test test_cancel_is_a_fail "a cancelled check -> exit 1"
run_test test_fail_beats_pending "fail beats pending"
run_test test_pending_then_pass "pending then pass keeps polling"
run_test test_empty_check_list_is_pending_not_pass "empty check list is pending, never pass"
run_test test_stuck_ci_stops_at_ceiling "stuck CI stops at the 45-min ceiling (exit 9)"
run_test test_timeout_env_moves_the_ceiling "LIBRARIAN_CI_WAIT_* reach the bound"
run_test test_l2_exits_at_checkpoint "L2 exits at the checkpoint (exit 8)"
run_test test_resume_after_checkpoint_extend "resume after a checkpoint Extend"
run_test test_resumed_elapsed_counts_toward_ceiling "carried --elapsed-min counts toward the ceiling"
run_test test_verdict_comes_from_the_timeout_helper "verdict is delegated to ci-wait-timeout.sh"
run_test test_bad_level_fails_loud_via_helper "bad --level fails loud via the helper"
run_test test_gh_error_is_exit_3_not_pass "gh error -> exit 3, never pass"
run_test test_hung_gh_is_bounded "a hung gh call is bounded -> exit 3"
run_test test_usage_errors "usage errors -> exit 2 before any poll"
run_test test_bad_poll_timeout_env_fails_loud "bad LIBRARIAN_CI_WAIT_POLL_TIMEOUT -> exit 2"

generate_report
