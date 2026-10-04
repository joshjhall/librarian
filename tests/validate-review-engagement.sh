#!/usr/bin/env bash
# review-engagement.sh — transcript-measured dimension engagement (issue #1111).
#
# The harness cannot see its dimensions' tool calls or tokens (agent() returns
# only the schema object), so this script measures them from the Workflow
# transcript dir and folds them into the cycle result. Each case below is built
# on a fixture where the pre-#1111 behavior gives the wrong answer:
#
#   the issue's signature (one StructuredOutput call, 53 tokens, findings: [])
#       on security                         -> flagged unengaged, clean:false
#   the SAME signature on scope-drift       -> NOT flagged (operator note: it is
#       legitimately diff-only; flagging it would block convergence forever)
#   usage repeated once per content block   -> counted once per message id
#   an opus retry after an empty first run  -> judged on the LAST run
#   no review agents in the dir             -> engagement_measured:false + WARNING
#   unreadable input                        -> exit 2, result untouched
#
# Pure bash + jq via `command`. bash-3.2 clean, BSD-regex clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RE="$REPO_ROOT/plugins/workflow/scripts/review-engagement.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-engagement.sh transcript measurement (#1111)"

SANDBOX="$(command mktemp -d)"
trap 'command rm -rf "$SANDBOX"' EXIT

# val <key> <output> — echo the value of a `key=value` line.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# agent <dir> <id> <dim> <model> <jsonl-lines...> — write one agent's meta +
# transcript, and append its `started` line to the journal (dispatch order).
agent() {
    local dir="$1" id="$2" dim="$3" model="$4"
    shift 4
    command mkdir -p "$dir"
    command printf '{"agentType":"dev-core:code-reviewer","description":"review:%s","model":"%s"}\n' \
        "$dim" "$model" >"$dir/agent-$id.meta.json"
    : >"$dir/agent-$id.jsonl"
    local line
    for line in "$@"; do
        command printf '%s\n' "$line" >>"$dir/agent-$id.jsonl"
    done
    command printf '{"type":"started","agentId":"%s"}\n' "$id" >>"$dir/journal.jsonl"
}

# Transcript lines. An assistant turn is one line per content block, each
# repeating that turn's usage — the shape that makes a naive sum over-count.
user='{"type":"user","message":{"role":"user","content":"x"}}'
so() { command printf '{"type":"assistant","message":{"id":"%s","content":[{"type":"tool_use","name":"StructuredOutput"}],"usage":{"output_tokens":%s}}}' "$1" "$2"; }
# A turn that records the answering model, as real transcripts do.
so_model() { command printf '{"type":"assistant","message":{"id":"%s","model":"%s","content":[{"type":"tool_use","name":"StructuredOutput"}],"usage":{"output_tokens":%s}}}' "$1" "$2" "$3"; }
tool() { command printf '{"type":"assistant","message":{"id":"%s","content":[{"type":"tool_use","name":"%s"}],"usage":{"output_tokens":%s}}}' "$1" "$2" "$3"; }
text() { command printf '{"type":"assistant","message":{"id":"%s","content":[{"type":"text","text":"t"}],"usage":{"output_tokens":%s}}}' "$1" "$2"; }

# The harness's own engagement map: which dimensions must read code.
ENG='{"security":{"requires_code_reading":true},"correctness":{"requires_code_reading":true},"scope-drift":{"requires_code_reading":false}}'

clean_result() {
    command printf '{"blocking":[],"deferrable":[],"clean":true,"budget_exhausted":false,"dimensions_skipped":[],"unengaged_dimensions":[],"dimension_engagement":%s}\n' "$ENG" >"$1"
}

test_empty_submit_security_is_unengaged() {
    local d="$SANDBOX/empty-sec" r="$SANDBOX/empty-sec.json" out
    # THE issue's measured signature: 53 tokens, one StructuredOutput call.
    agent "$d" a1 security sonnet "$user" "$(so m1 53)"
    agent "$d" a2 correctness sonnet "$user" "$(tool m2 Read 200)" "$(so m3 80)"
    clean_result "$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "true" "$(val measured "$out")" "the dir had review agents, so engagement was measured"
    assert_equals "1" "$(val unengaged "$out")" "exactly one dimension is unengaged"
    assert_equals '["security"]' "$(command jq -c '.unengaged_dimensions' "$r")" "the empty-submit security run is flagged (#1111 AC1)"
    assert_equals "true" "$(command jq -r '.dimensions_skipped | index("security") != null' "$r")" "and listed in dimensions_skipped"
    assert_equals "false" "$(command jq -r '.clean' "$r")" "the cycle is no longer clean"
    assert_equals "true" "$(command jq -r '.budget_exhausted' "$r")" "the cycle is marked partial"
    assert_equals "0" "$(command jq -r '.dimension_metrics.security[0].tool_calls' "$r")" "StructuredOutput is not an investigative call"
    assert_equals "53" "$(command jq -r '.dimension_metrics.security[0].output_tokens' "$r")" "the 53-token run is measured exactly (AC4)"
    assert_equals "1" "$(command jq -r '.dimension_metrics.correctness[0].tool_calls' "$r")" "an engaged dimension's Read is counted"
    assert_equals "280" "$(command jq -r '.dimension_metrics.correctness[0].output_tokens' "$r")" "and its tokens summed across turns"
}

test_diff_only_scope_drift_is_not_flagged() {
    # The operator's correction: scope-drift compares the diff to the issue, so
    # zero tool calls is its NORMAL shape. Same signature as the security case.
    local d="$SANDBOX/scope" r="$SANDBOX/scope.json" out
    agent "$d" b1 scope-drift sonnet "$user" "$(so n1 53)"
    clean_result "$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "a diff-only scope-drift run is not unengaged"
    assert_equals "true" "$(command jq -r '.clean' "$r")" "and the cycle stays clean"
    assert_equals "0" "$(command jq -r '.dimension_metrics["scope-drift"][0].tool_calls' "$r")" "its metrics are still reported"
}

test_dimension_with_a_finding_is_not_flagged() {
    local d="$SANDBOX/found" r="$SANDBOX/found.json" out
    agent "$d" c1 security sonnet "$user" "$(so p1 300)"
    command printf '{"blocking":[{"dimension":"security","file":"a.js"}],"deferrable":[],"clean":false,"dimension_engagement":%s}\n' "$ENG" >"$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "a dimension that produced a finding engaged, whatever its tool count"
}

test_raw_finding_count_exempts_a_dimension() {
    # A code-reading dimension with zero tool calls whose findings are NOT in
    # the post-judge arrays, but whose raw count the harness recorded, is
    # engaged: the raw count is the source, not the arrays (cycle-4 review).
    local d="$SANDBOX/raw" r="$SANDBOX/raw.json" out
    agent "$d" r1 security sonnet "$user" "$(so w1 300)"
    command printf '{"blocking":[],"deferrable":[],"clean":true,"dimension_engagement":{"security":{"requires_code_reading":true,"findings":2}}}\n' >"$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "a recorded raw finding count exempts the dimension"
}

test_usage_repeated_per_block_counts_once() {
    local d="$SANDBOX/dedupe" r="$SANDBOX/dedupe.json"
    # One 3-block turn repeating output_tokens=100, then a 1-block turn of 40.
    agent "$d" e1 correctness sonnet "$user" \
        "$(text q1 100)" "$(tool q1 Grep 100)" "$(tool q1 Read 100)" "$(so q2 40)"
    clean_result "$r"
    "$RE" "$d" "$r" >/dev/null
    assert_equals "140" "$(command jq -r '.dimension_metrics.correctness[0].output_tokens' "$r")" "usage is summed once per message id, not per block"
    assert_equals "2" "$(command jq -r '.dimension_metrics.correctness[0].tool_calls' "$r")" "tool_use blocks are counted per block"
}

test_partial_trailing_line_is_tolerated() {
    local d="$SANDBOX/partial" r="$SANDBOX/partial.json"
    agent "$d" f1 correctness sonnet "$user" "$(tool s1 Read 90)" '{"type":"assistant","mess'
    clean_result "$r"
    "$RE" "$d" "$r" >/dev/null
    assert_equals "1" "$(command jq -r '.dimension_metrics.correctness[0].tool_calls' "$r")" "a mid-write trailing line does not kill the parse"
}

test_opus_retry_judged_on_last_run() {
    local d="$SANDBOX/retry" r="$SANDBOX/retry.json" out
    # Sonnet answers empty, the harness re-dispatches on opus, opus reads.
    agent "$d" g1 security sonnet "$user" "$(so t1 53)"
    agent "$d" g2 security opus "$user" "$(tool t2 Read 400)" "$(so t3 60)"
    clean_result "$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "an engaged opus retry clears the dimension"
    assert_equals "2" "$(command jq -r '.dimension_metrics.security | length' "$r")" "both runs are reported"
    assert_equals "opus" "$(command jq -r '.dimension_metrics.security[1].model' "$r")" "in dispatch order, retry last"

    # And the converse: the retry ALSO empty -> still unengaged.
    local d2="$SANDBOX/retry2" r2="$SANDBOX/retry2.json"
    agent "$d2" h1 security sonnet "$user" "$(so u1 53)"
    agent "$d2" h2 security opus "$user" "$(so u2 55)"
    clean_result "$r2"
    out="$("$RE" "$d2" "$r2")"
    assert_equals "1" "$(val unengaged "$out")" "an empty retry leaves the dimension unengaged"
}

test_model_read_from_transcript() {
    # Measured on a live review run: an inheriting dimension's meta.json has NO
    # `model` key; the model that answered is on each assistant message.
    local d="$SANDBOX/model" r="$SANDBOX/model.json"
    command mkdir -p "$d"
    command printf '{"description":"review:tests"}\n' >"$d/agent-k1.meta.json"
    command printf '%s\n%s\n' "$(tool v1 Read 10)" "$(so_model v2 claude-sonnet-5-5 20)" >"$d/agent-k1.jsonl"
    clean_result "$r"
    "$RE" "$d" "$r" >/dev/null
    assert_equals "claude-sonnet-5-5" "$(command jq -r '.dimension_metrics.tests[0].model' "$r")" "the transcript's message.model is reported"
}

test_journal_id_cannot_escape_the_dir() {
    # A journal agentId is file content that becomes a path: `$dir/agent-$id`.
    # The id `x/../../agent-out` resolves from run/ to ../agent-out.*, a review
    # agent OUTSIDE the transcript dir. Without the id guard it is measured and
    # flags `security` — verified by deleting the guard (this case went red).
    local base="$SANDBOX/escape" d="$SANDBOX/escape/run" r="$SANDBOX/escape.json" out
    command mkdir -p "$d/agent-x"
    command printf '{"description":"review:security"}\n' >"$base/agent-out.meta.json"
    command printf '%s\n' "$(so x1 53)" >"$base/agent-out.jsonl"
    command printf '{"type":"started","agentId":"x/../../agent-out"}\n' >"$d/journal.jsonl"
    # Precondition: the traversal really resolves, so a pass is the guard's
    # doing and not a path that never existed.
    assert_equals "yes" "$([ -r "$d/agent-x/../../agent-out.meta.json" ] && echo yes || echo no)" "fixture: the traversal path resolves outside the dir"
    clean_result "$r"
    out="$("$RE" "$d" "$r" 2>/dev/null)"
    assert_equals "false" "$(val measured "$out")" "a traversal id is skipped, so nothing outside the dir is measured"
    assert_equals "true" "$(command jq -r '.clean' "$r")" "and the outside agent cannot flag a dimension"
}

# noj_agent <dir> <id> <dim> <model> <lines...> — like agent(), but writes NO
# journal line: the no-journal fallback, where only file-name order exists.
noj_agent() {
    local dir="$1" id="$2" dim="$3" model="$4"
    shift 4
    command mkdir -p "$dir"
    command printf '{"description":"review:%s"}\n' "$dim" >"$dir/agent-$id.meta.json"
    : >"$dir/agent-$id.jsonl"
    local line
    for line in "$@"; do
        command printf '%s\n' "$line" >>"$dir/agent-$id.jsonl"
    done
}

# A tool-calling turn that records its model.
toolm() { command printf '{"type":"assistant","message":{"id":"%s","model":"%s","content":[{"type":"tool_use","name":"%s"}],"usage":{"output_tokens":%s}}}' "$1" "$2" "$3" "$4"; }

retry_result() {
    # $1 = file, $2 = retry_attempted, $3 = retry_succeeded
    command printf '{"blocking":[],"deferrable":[],"clean":true,"dimension_engagement":{"correctness":{"requires_code_reading":true,"findings":0,"retry_attempted":%s,"retry_succeeded":%s}}}\n' "$2" "$3" >"$1"
}

test_kept_run_is_found_without_journal_order() {
    # The cycle-6 case. NO journal, and the engaged OPUS retry's id (a0...)
    # sorts BEFORE the empty sonnet run's id (af...), so file-name order puts
    # the sonnet run LAST. The old `[-1]` flagged this; the harness had kept
    # the opus result, so it is engaged.
    local d="$SANDBOX/noj" r="$SANDBOX/noj.json" out
    noj_agent "$d" a0opus correctness opus "$user" "$(toolm o1 claude-opus-5-5 Read 400)" "$(so_model o2 claude-opus-5-5 60)"
    noj_agent "$d" afsonnet correctness sonnet "$user" "$(so_model s1 claude-sonnet-5-5 53)"
    [ ! -e "$d/journal.jsonl" ] || return 1
    retry_result "$r" true true
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "a succeeded opus retry is judged, whatever the file-name order"
    assert_equals "true" "$(command jq -r '.clean' "$r")" "and the cycle stays clean"
}

test_failed_retry_judges_the_kept_sonnet_run() {
    # The retry ran but its result was NOT kept (retry_succeeded false), so the
    # empty sonnet answer stands: unengaged, even though an opus run with tool
    # calls exists in the transcript.
    local d="$SANDBOX/noj2" r="$SANDBOX/noj2.json" out
    noj_agent "$d" a0opus correctness opus "$user" "$(toolm p1 claude-opus-5-5 Read 400)"
    noj_agent "$d" afsonnet correctness sonnet "$user" "$(so_model q1 claude-sonnet-5-5 53)"
    retry_result "$r" true false
    out="$("$RE" "$d" "$r")"
    assert_equals "1" "$(val unengaged "$out")" "a retry whose result was not kept leaves the sonnet answer judged"
}

test_ambiguous_multi_run_flags_only_if_every_run_empty() {
    # No harness retry signal (an older harness) and several runs: flag only
    # when EVERY run made zero calls, so ambiguity never manufactures a verdict.
    local d="$SANDBOX/amb" r="$SANDBOX/amb.json" out
    noj_agent "$d" a0x correctness opus "$user" "$(toolm t1 claude-opus-5-5 Read 400)"
    noj_agent "$d" afy correctness sonnet "$user" "$(so_model t2 claude-sonnet-5-5 53)"
    command printf '{"blocking":[],"deferrable":[],"clean":true,"dimension_engagement":{"correctness":{"requires_code_reading":true}}}\n' >"$r"
    out="$("$RE" "$d" "$r")"
    assert_equals "0" "$(val unengaged "$out")" "one engaged run among several is not flagged when the kept run is unknown"
    local d2="$SANDBOX/amb2" r2="$SANDBOX/amb2.json"
    noj_agent "$d2" a0x correctness opus "$user" "$(so_model u1 claude-opus-5-5 55)"
    noj_agent "$d2" afy correctness sonnet "$user" "$(so_model u2 claude-sonnet-5-5 53)"
    command printf '{"blocking":[],"deferrable":[],"clean":true,"dimension_engagement":{"correctness":{"requires_code_reading":true}}}\n' >"$r2"
    out="$("$RE" "$d2" "$r2")"
    assert_equals "1" "$(val unengaged "$out")" "every run empty is still flagged"
}

test_rerun_is_idempotent() {
    # Running twice on one result must not duplicate a flagged dimension.
    local d="$SANDBOX/idem" r="$SANDBOX/idem.json"
    agent "$d" i1 security sonnet "$user" "$(so i2 53)"
    clean_result "$r"
    "$RE" "$d" "$r" >/dev/null
    "$RE" "$d" "$r" >/dev/null
    assert_equals '["security"]' "$(command jq -c '.unengaged_dimensions' "$r")" "a second run does not duplicate unengaged_dimensions"
    assert_equals "1" "$(command jq -r '[.dimensions_skipped[] | select(. == "security")] | length' "$r")" "nor dimensions_skipped"
}

test_missing_jq_fails_loud() {
    # A PATH with bash but no jq: exit 2, result untouched, never a silent 0.
    local bin="$SANDBOX/nojq-bin" r="$SANDBOX/nojq.json" before rc=0 tool
    # Precondition, so a pass is the script's doing: jq truly is unreachable.
    command mkdir -p "$bin"
    command ln -sf "$(command -v bash)" "$bin/bash"
    assert_equals "absent" "$(/usr/bin/env -uBASH_ENV PATH="$bin" "$bin/bash" -c 'command -v jq >/dev/null && echo present || echo absent')" "fixture: jq is not reachable on the stripped PATH"
    command mkdir -p "$bin"
    for tool in bash mktemp rm cat; do
        command ln -sf "$(command -v "$tool")" "$bin/$tool"
    done
    clean_result "$r"
    before="$(command cat "$r")"
    # -uBASH_ENV: a BASH_ENV file (e.g. /etc/bash_env) is sourced by every
    # non-interactive bash and can restore PATH, putting jq back and making this
    # case pass vacuously. Measured: without the scrub it exited 0 here.
    /usr/bin/env -uBASH_ENV PATH="$bin" "$bin/bash" "$RE" "$SANDBOX" "$r" >/dev/null 2>"$SANDBOX/nojq.err" || rc=$?
    assert_equals "2" "$rc" "missing jq exits 2"
    # The exit code alone cannot pin the guard: without it, the later
    # `jq -e type == "object"` check fails on the missing binary and dies with a
    # MISLEADING "not a JSON object" (still exit 2; measured). The guard's value is
    # the actionable message, so that is what is asserted.
    assert_contains "$(command cat "$SANDBOX/nojq.err")" "jq is required" "and names jq as the missing runtime"
    assert_equals "$before" "$(command cat "$r")" "and leaves the result untouched"
}

test_no_review_agents_is_not_a_clean_measurement() {
    local d="$SANDBOX/none" r="$SANDBOX/none.json" out err
    command mkdir -p "$d"
    command printf '{"description":"manifest","model":"sonnet"}\n' >"$d/agent-z1.meta.json"
    : >"$d/agent-z1.jsonl"
    clean_result "$r"
    out="$("$RE" "$d" "$r" 2>"$SANDBOX/none.err")"
    err="$(command cat "$SANDBOX/none.err")"
    assert_equals "false" "$(val measured "$out")" "a dir with no review agents reports measured=false"
    assert_equals "false" "$(command jq -r '.engagement_measured' "$r")" "and records it in the result"
    assert_contains "$err" "engagement NOT measured" "with a WARNING on stderr"
}

test_unreadable_input_fails_loud() {
    local r="$SANDBOX/loud.json" before rc
    clean_result "$r"
    before="$(command cat "$r")"
    rc=0
    "$RE" "$SANDBOX/does-not-exist" "$r" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "a missing transcript dir exits 2"
    assert_equals "$before" "$(command cat "$r")" "and leaves the result untouched"
    rc=0
    "$RE" "$SANDBOX" "$SANDBOX/no-such.json" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "a missing result file exits 2"
    command printf '[1]\n' >"$SANDBOX/array.json"
    rc=0
    "$RE" "$SANDBOX" "$SANDBOX/array.json" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "a non-object result exits 2"
}

run_test test_empty_submit_security_is_unengaged "empty-submit security is flagged unengaged"
run_test test_diff_only_scope_drift_is_not_flagged "diff-only scope-drift is engaged (operator note)"
run_test test_dimension_with_a_finding_is_not_flagged "a dimension with a finding is engaged"
run_test test_raw_finding_count_exempts_a_dimension "raw finding count exempts a dimension"
run_test test_usage_repeated_per_block_counts_once "usage dedupe by message id"
run_test test_partial_trailing_line_is_tolerated "partial trailing transcript line"
run_test test_opus_retry_judged_on_last_run "opus retry judged on the last run"
run_test test_model_read_from_transcript "model comes from message.model, not meta"
run_test test_journal_id_cannot_escape_the_dir "journal agentId cannot escape the transcript dir"
run_test test_kept_run_is_found_without_journal_order "no journal: the kept opus run is judged (cycle-6 case)"
run_test test_failed_retry_judges_the_kept_sonnet_run "retry not kept: the sonnet answer is judged"
run_test test_ambiguous_multi_run_flags_only_if_every_run_empty "no retry signal: flag only if every run empty"
run_test test_rerun_is_idempotent "second run does not duplicate flags"
run_test test_missing_jq_fails_loud "missing jq -> exit 2, result untouched"
run_test test_no_review_agents_is_not_a_clean_measurement "no review agents -> measured=false"
run_test test_unreadable_input_fails_loud "unreadable input -> exit 2"

generate_report
