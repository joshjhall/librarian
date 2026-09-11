#!/usr/bin/env bash
# token-attribute behavioral gate (issue #788).
#
# WHAT THIS GATE IS FOR. #788 did not ask for coverage of a reporting tool. It
# asked for four transcript-parsing traps to be "encoded as assertions, not as
# comments" — because each one produces a number that is CONFIDENTLY WRONG
# rather than loudly broken. A wrong reading here looks plausible, gets quoted
# in an issue, and steers the #782–#787 series. So the subject of this suite is
# the four traps, and every other case exists to keep them honest.
#
# THE FOUR, AND WHAT EACH FIXTURE WOULD CATCH:
#
#   1. DEDUP by message.id. Claude Code writes one line per assistant CONTENT
#      BLOCK and every line of a turn repeats that turn's SAME usage. Summing
#      per line runs ~2x high (2.7x measured on a real transcript;
#      .claude/memory/token-scrape-transcript-dedup.md). The fixture makes raw
#      and deduped totals DIFFER and pins both, so removing the dedup moves a
#      pinned number — #788's AC3 in its own words.
#
#   2. UNION the blocks across those lines. The obvious dedup — group by id,
#      take .[0] — is a worse bug: the lines carry DIFFERENT blocks. An early
#      pass in the analysis that produced #788 reported 4 Bash calls where there
#      were 176. The fixture puts three DIFFERENT tool_use blocks on three lines
#      of ONE message.id; .[0] reports 1, and the assertion pins 3.
#
#   3. THINKING TOKENS live in usage.output_tokens_details.thinking_tokens. The
#      `thinking` content blocks are EMPTY STRINGS, so any character count over
#      content silently returns 0 and hides 55-86% of subagent output. The
#      fixture is exactly that shape: empty thinking blocks, non-zero usage.
#
#   4. TIMEZONE. Naive stamps are local; gateway figures are UTC. Mixing them
#      misfiles a 5-hour band of runs
#      (.claude/memory/review-cost-after-2026-07-28.md). The fixture crosses the
#      local/UTC date boundary and asserts it is classified by UTC.
#
# WHY THE FIXTURES ARE HAND-BUILT RATHER THAN SAMPLED. Every trap above is
# invisible on a healthy corpus — that is what makes it a trap. A real
# transcript cannot be asked for three different blocks under one id on demand,
# and a sampled fixture would stop discriminating the moment the sample changed.
#
# ONE CASE IS A CONTROL. test_union_beats_any_single_line asserts the unioned
# count is >= the largest single line's AND pins the exact figure. The
# inequality alone would pass on a tool that returned everything twice; the
# exact count alone would pass on a fixture that never had a duplicate id. Both
# together are what pin the behavior.
#
# Pure bash + coreutils via the `command` builtin; python3 for the tool itself.
# bash-3.2 clean, BSD-regex clean. Uses the shared harness assertions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SUITE_FILE="${BASH_SOURCE[0]}"
TA_PY="$REPO_ROOT/plugins/workflow/scripts/token-attribute.py"
TA_SH="$REPO_ROOT/plugins/workflow/scripts/token-attribute.sh"

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while realpath-based code resolves the same dir
# to /private/var/.... Any prefix match between the two spellings fails (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "token-attribute trap gate (#788)"

# The tool is Python-3.11+ only BY DESIGN — it parses JSONL and has no bash
# fallback (the decision is recorded in the tool's own header, #788 AC8). With
# no such runtime the WHOLE gate reports the reserved 77 sentinel rather than
# passing vacuously: a silent skip is indistinguishable from a pass, which is
# how a gate sits inert unnoticed (CLAUDE.md § gates; #538/#571).
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    command printf '%s\n' \
        "token-attribute gate: no python3 >= 3.11 — gate DID NOT RUN." >&2
    exit 77
fi

# --- helpers -----------------------------------------------------------------

# run_ta SUBCOMMAND ROOT [EXTRA...] — stdout+stderr into OUT, status into RC.
# Assigned to globals rather than run in a subshell so assertions land in the
# caller's shell where TEST_STATUS is real.
run_ta() {
    local sub="$1" root="$2"
    shift 2
    set +e
    OUT="$(python3 "$TA_PY" "$sub" --root "$root" "$@" 2>&1)"
    RC=$?
    set -e
}

# row_field ROW_MATCH FIELD_INDEX — the Nth tab-separated field of the first
# non-comment output row containing ROW_MATCH. 1-indexed, like awk.
#
# Reads from $OUT and strips /^#/ exactly as the TSV contract says a consumer
# does, so the assertions exercise the documented reading rather than a
# privileged one.
row_field() {
    command printf '%s\n' "$OUT" |
        command grep -v '^#' |
        command grep -F "$1" |
        command head -1 |
        command awk -F'\t' -v n="$2" '{print $n}'
}

# decile_field N FIELD — the FIELD of the row whose decile column (3) is N.
#
# A bare `row_field "<TAB>5<TAB>"` is ambiguous here and silently matched the
# WRONG row: decile 1 also carries a literal 5 (its output_tokens), and grep
# returns the first hit. That is the empty-TSV-column failure mode in a
# different dress — a selector that looks specific, matches something else, and
# reports a plausible number. Anchor on the column instead of the value.
decile_field() {
    command printf '%s\n' "$OUT" |
        command grep -v '^#' |
        command awk -F'\t' -v d="$1" -v n="$2" '$3 == d {print $n; exit}'
}

# --- TRAP 2 + TRAP 1: one message.id, three lines, different blocks ----------
#
# The shape that makes both traps visible at once, and the shape no real
# transcript can be asked to produce on demand:
#
#   line 1  id=msgDUP  blocks: [thinking]                     usage: 900 output
#   line 2  id=msgDUP  blocks: [tool_use grep]                 usage: 900 (repeat)
#   line 3  id=msgDUP  blocks: [tool_use git status, tool_use rm]        (repeat)
#
# Correct reading: 3 tool_use blocks, 900 output tokens.
#   .[0]        -> 0 tool_use blocks (line 1 is the thinking line)
#   per-line    -> 2700 output tokens, a 3x overstatement
#
# All three are Bash calls on purpose: `bash-class` is the subcommand that can
# count them, and their three DIFFERENT classifications (read/read/mutate) mean
# a tool that dropped any one of them changes a pinned number rather than just
# the total.
#
# The three tool_use ids are distinct so the within-turn dedup cannot collapse
# them; a fixture reusing one id would pass on a tool that dropped two.
DUP="$WORKDIR/dup"
command mkdir -p "$DUP/proj"
{
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T10:00:00.000Z","message":{"id":"msgDUP","role":"assistant","model":"claude-opus-5","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":900,"output_tokens_details":{"thinking_tokens":700}}}}\n'
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T10:00:00.000Z","message":{"id":"msgDUP","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tu_a","name":"Bash","input":{"command":"grep -rn foo ."}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":900,"output_tokens_details":{"thinking_tokens":700}}}}\n'
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T10:00:00.000Z","message":{"id":"msgDUP","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tu_b","name":"Bash","input":{"command":"git status"}},{"type":"tool_use","id":"tu_c","name":"Bash","input":{"command":"rm -rf build"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":900,"output_tokens_details":{"thinking_tokens":700}}}}\n'
} >"$DUP/proj/session.jsonl"

test_union_beats_any_single_line() {
    # THE TRAP-2 ASSERTION #788 asks for in AC2, in both halves: the unioned
    # count must be at least any single line's, AND it must be the exact 3.
    run_ta bash-class "$DUP"
    assert_equals "0" "$RC" "the duplicate-id corpus reports"

    local read_calls mutate_calls total
    read_calls="$(row_field "	read	" 4)"
    mutate_calls="$(row_field "	mutate	" 4)"
    total=$((read_calls + mutate_calls))

    # >= the largest single line (that line carries 2). Guards against a
    # regression that reads one line and happens to pick the richest.
    assert_true "[ $total -ge 2 ]" "unioned blocks are at least any single line's"
    # And the exact figure: .[0] would report 0, the second line alone 1.
    assert_equals "3" "$total" "all three tool_use blocks survive the union"
    # The classification also has to be right, or the count above could be 3 by
    # accident of everything landing in one bucket.
    assert_equals "2" "$read_calls" "grep and git status classify as read"
    assert_equals "1" "$mutate_calls" "rm -rf classifies as mutate"
}

test_usage_is_not_summed_per_line() {
    # THE TRAP-1 ASSERTION (AC3): raw summation and deduped totals differ on
    # this fixture — 2700 vs 900 — and the deduped figure is what is emitted.
    # Removing the dedup moves this pinned number, which is the property #788
    # asks for ("so the dedup cannot be quietly removed").
    run_ta growth "$DUP"
    assert_equals "0" "$RC" "growth reports on the duplicate-id corpus"

    local output_tokens turns
    output_tokens="$(decile_field 1 6)"
    turns="$(decile_field 1 4)"

    assert_equals "1" "$turns" "three lines of one id are ONE turn, not three"
    assert_equals "900" "$output_tokens" "usage is read once per id, not summed per line"
    assert_not_contains "$OUT" "	2700	" "the naive per-line sum (2700) is never emitted"
}

# --- TRAP 3: thinking tokens are in usage, and the blocks are empty ----------
#
# The fixture is the exact shape that defeats a character count: the `thinking`
# content blocks hold EMPTY STRINGS while usage reports 700 + 1300. A tool
# measuring the blocks reports 0 and nobody notices, because 0 thinking tokens
# is a believable reading.
THINK="$WORKDIR/thinking"
command mkdir -p "$THINK/proj"
{
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T10:00:00.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":5,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":100,"output_tokens_details":{"thinking_tokens":700}}}}\n'
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T10:05:00.000Z","message":{"id":"m2","role":"assistant","model":"claude-opus-5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"done"}],"usage":{"input_tokens":5,"cache_read_input_tokens":700,"cache_creation_input_tokens":0,"output_tokens":200,"output_tokens_details":{"thinking_tokens":1300}}}}\n'
} >"$THINK/proj/session.jsonl"

test_thinking_tokens_come_from_usage_not_content() {
    run_ta growth "$THINK"
    assert_equals "0" "$RC" "the empty-thinking-block corpus reports"

    # Both turns land in the first decile (n=2 over 10 buckets puts turn 1 in
    # bucket 1); the assertion is that SOME bucket carries a non-zero figure and
    # that the total is exactly the usage sum.
    local total
    total="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{s += $7} END {print s+0}')"
    assert_equals "2000" "$total" "thinking tokens are summed from usage (700+1300)"
    # The failure this pins: a character count over the empty blocks yields 0.
    assert_true "[ $total -ne 0 ]" "empty thinking blocks do not read as zero thinking"
}

test_thinking_is_not_derived_from_block_text() {
    # A SECOND, independent reading of trap 3. The fixture above could pass on a
    # tool that guessed thinking from output_tokens. Here output_tokens and
    # thinking_tokens differ, so a tool substituting one for the other fails.
    run_ta growth "$THINK"
    local thinking output
    thinking="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{s += $7} END {print s+0}')"
    output="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{s += $6} END {print s+0}')"
    assert_equals "300" "$output" "output tokens total 100+200"
    assert_true "[ $thinking -ne $output ]" \
        "thinking is read from its own field, not substituted from output_tokens"
}

# --- TRAP 4: a naive stamp straddling the local/UTC boundary -----------------
#
# `2026-08-23T22:30:00` with NO offset. Read as America/New_York (UTC-4 in
# August) it is 2026-08-24T02:30Z — the NEXT DAY. Read naively as UTC it stays
# on the 23rd. That one-day slip is exactly the 5-hour misfiling recorded in
# .claude/memory/review-cost-after-2026-07-28.md, and it is invisible in any
# window that does not cross a boundary — which is why the fixture crosses one.
TZF="$WORKDIR/tz"
command mkdir -p "$TZF/proj"
{
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T22:30:00","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":5,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":100}}}\n'
} >"$TZF/proj/session.jsonl"

test_naive_timestamp_is_normalized_to_utc() {
    run_ta growth "$TZF" --tz America/New_York
    assert_equals "0" "$RC" "a naive stamp under an explicit --tz reports"

    local window
    window="$(decile_field 1 1)"
    # THE ASSERTION (AC5): the emitted window_start is UTC, and under UTC-4 that
    # is the NEXT day. A naive local reading would emit 2026-08-23T22:30.
    assert_contains "$window" "2026-08-24T02:30:00" "a naive stamp is converted to UTC"
    assert_contains "$window" "+00:00" "and is emitted with an explicit UTC offset"
    assert_not_contains "$window" "2026-08-23T22:30" "the naive local reading is never emitted"
}

test_same_instant_reads_identically_under_either_spelling() {
    # The other direction, and the one that proves the conversion is real rather
    # than a fixed offset added to everything: an AWARE stamp naming the same
    # instant must produce the SAME window_start, whatever --tz says. A tool
    # that blindly applied --tz would shift this one too.
    local aware="$WORKDIR/tz-aware"
    command mkdir -p "$aware/proj"
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-24T02:30:00Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":5,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":100}}}\n' \
        >"$aware/proj/session.jsonl"

    run_ta growth "$aware" --tz America/New_York
    local aware_window
    aware_window="$(decile_field 1 1)"
    run_ta growth "$TZF" --tz America/New_York
    local naive_window
    naive_window="$(decile_field 1 1)"
    assert_equals "$aware_window" "$naive_window" \
        "an aware stamp and its naive local spelling land on the same instant"
}

test_unknown_timezone_fails_loudly() {
    # --tz is the knob that makes trap 4 avoidable, so a typo in it must not
    # degrade to "whatever the machine's zone is" — that is the silent-local
    # reading the trap is made of.
    run_ta growth "$TZF" --tz Not/AZone
    assert_true "[ $RC -ne 0 ]" "an unknown zone does not exit 0"
    assert_contains "$OUT" "unknown timezone" "and says which knob was wrong"
}

# --- the TSV contract (AC6) --------------------------------------------------

test_every_subcommand_emits_the_join_key() {
    # AC6: output must join against token-report.sh's window output, which keys
    # on (window_start, model). Asserted for EVERY subcommand rather than one,
    # because the contract is what makes gateway and transcript numbers
    # comparable and a single divergent subcommand breaks the join silently.
    local sub
    for sub in debt floor growth prefix bash-class attachments; do
        run_ta "$sub" "$CONTRACT"
        assert_equals "0" "$RC" "$sub reports on the contract corpus"
        assert_contains "$OUT" "# columns: window_start	model" \
            "$sub declares the window_start+model join key first"

        local first_row
        first_row="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
            command head -1)"
        assert_contains "$first_row" "claude-opus-5" \
            "$sub emits the model read from the transcript, not a placeholder"
    done
}

test_rows_are_tab_separated_with_no_empty_fields() {
    # An EMPTY field collapses under a TSV reader's field split, shifting every
    # later column left — so a consumer reading column 6 silently gets column 7
    # (the repo has this recorded as a class). Every field must be non-empty;
    # the tool spells an absent value `-`.
    run_ta debt "$CONTRACT"
    local bad
    bad="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{for (i = 1; i <= NF; i++) if ($i == "") print NR}')"
    assert_equals "" "$bad" "no row carries an empty field"
}

test_absent_timestamp_emits_a_sentinel_not_a_blank() {
    # The specific case the rule above exists for: a corpus whose records carry
    # no parseable timestamp. window_start has no value, and the wrong answer is
    # an empty first field.
    local nots="$WORKDIR/no-ts"
    command mkdir -p "$nots/proj"
    command printf '{"type":"assistant","sessionId":"s1","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":5,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":100}}}\n' \
        >"$nots/proj/session.jsonl"
    run_ta growth "$nots"
    assert_equals "0" "$RC" "a stampless corpus still reports"
    local first
    first="$(command printf '%s\n' "$OUT" | command grep -v '^#' | command head -1 |
        command awk -F'\t' '{print $1}')"
    assert_equals "-" "$first" "an unknown window_start is the sentinel, not empty"
}

# --- the contract corpus -----------------------------------------------------
#
# One session with tool calls, results, attachments, and a spawn — enough for
# every subcommand to produce at least one row. Deliberately separate from the
# trap fixtures above, which are minimal on purpose.
CONTRACT="$WORKDIR/contract"
command mkdir -p "$CONTRACT/proj/sess/subagents/wf"
{
    command printf '{"type":"attachment","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","attachment":{"type":"prompt_snapshot","systemPrompt":"%s"}}\n' \
        "$(command printf 'x%.0s' $(command seq 1 400))"
    command printf '{"type":"attachment","sessionId":"s1","timestamp":"2026-08-23T09:00:01.000Z","attachment":{"type":"instructions","files":"%s"}}\n' \
        "$(command printf 'y%.0s' $(command seq 1 200))"
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:02.000Z","message":{"id":"c1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"grep -rn pattern ."}}],"usage":{"input_tokens":10,"cache_read_input_tokens":2000,"cache_creation_input_tokens":100,"output_tokens":50,"output_tokens_details":{"thinking_tokens":20}}}}\n'
    command printf '{"type":"user","sessionId":"s1","timestamp":"2026-08-23T09:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"%s"}]}}\n' \
        "$(command printf 'z%.0s' $(command seq 1 12000))"
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:04.000Z","message":{"id":"c2","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"cache_read_input_tokens":14000,"cache_creation_input_tokens":0,"output_tokens":30}}}\n'
} >"$CONTRACT/proj/session.jsonl"
command printf '{"type":"assistant","sessionId":"sp1","timestamp":"2026-08-23T09:00:05.000Z","message":{"id":"s1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"spawned"}],"usage":{"input_tokens":2,"cache_read_input_tokens":20000,"cache_creation_input_tokens":4000,"output_tokens":40,"output_tokens_details":{"thinking_tokens":15}}}}\n' \
    >"$CONTRACT/proj/sess/subagents/wf/agent-one.jsonl"

# --- re-read debt arithmetic -------------------------------------------------

test_debt_is_size_times_residency_not_size() {
    # The arithmetic that makes `debt` different from a size ranking, and the
    # reason Bash carried 76% of re-read debt while not being the largest single
    # result. The fixture has a SMALL early result and a LARGE late one, chosen
    # so the two orderings disagree: ranking by size puts Read first, ranking by
    # debt puts Bash first.
    local dbt="$WORKDIR/debt"
    command mkdir -p "$dbt/proj"
    {
        command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"d1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tuA","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
        command printf '{"type":"user","sessionId":"s1","timestamp":"2026-08-23T09:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tuA","content":"%s"}]}}\n' \
            "$(command printf 'a%.0s' $(command seq 1 12000))"
        local i
        for i in 1 2 3 4 5 6 7 8; do
            command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:0%s:00.000Z","message":{"id":"pad%s","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"pad"}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' "$i" "$i"
        done
        command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:09:00.000Z","message":{"id":"d2","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tuB","name":"Read","input":{"file_path":"/x"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
        command printf '{"type":"user","sessionId":"s1","timestamp":"2026-08-23T09:09:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tuB","content":"%s"}]}}\n' \
            "$(command printf 'b%.0s' $(command seq 1 20000))"
    } >"$dbt/proj/session.jsonl"

    run_ta debt "$dbt"
    assert_equals "0" "$RC" "the debt corpus reports"

    local bash_tokens read_tokens bash_debt read_debt
    bash_tokens="$(row_field "	Bash	" 5)"
    read_tokens="$(row_field "	Read	" 5)"
    bash_debt="$(row_field "	Bash	" 6)"
    read_debt="$(row_field "	Read	" 6)"

    # The premise: Read's single result IS the larger one.
    assert_true "[ $read_tokens -gt $bash_tokens ]" \
        "the late Read result is larger than the early Bash one"
    # The finding: Bash nonetheless carries more debt, because it is re-sent for
    # the rest of the session. A tool ranking by size alone inverts this.
    assert_true "[ $bash_debt -gt $read_debt ]" \
        "the earlier, smaller result carries MORE re-read debt"
    # And the first row is the highest-debt one, not the largest.
    assert_contains "$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command head -1)" "Bash" "rows are ordered by debt, not by size"
}

test_trivial_results_are_floored_out() {
    # Without the floor the debt table is dominated by hundreds of status lines
    # whose products are noise. A result under RESULT_FLOOR_TOKENS contributes
    # nothing — asserted so the floor cannot be dropped silently.
    local tiny="$WORKDIR/tiny"
    command mkdir -p "$tiny/proj"
    {
        command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"t1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tuT","name":"Bash","input":{"command":"pwd"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
        command printf '{"type":"user","sessionId":"s1","timestamp":"2026-08-23T09:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tuT","content":"/workspace"}]}}\n'
    } >"$tiny/proj/session.jsonl"
    run_ta debt "$tiny"
    assert_equals "3" "$RC" "a corpus of only trivial results is an ABSENT measurement"
    assert_contains "$OUT" "no tool results over" "and says why"
}

# --- floor vs attachments: fixed vs open vocabulary --------------------------

test_floor_vocabulary_is_fixed_and_attachments_is_open() {
    # These two subcommands deliberately disagree, and the disagreement is
    # load-bearing: a FLOOR whose categories drift cannot be compared between
    # two measurements, while an ATTACHMENT census with a fixed list would have
    # filtered out the unexpected type that produced the no-op `hook_success`
    # finding in the first place.
    local mixed="$WORKDIR/mixed"
    command mkdir -p "$mixed/proj"
    {
        command printf '{"type":"attachment","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","attachment":{"type":"prompt_snapshot","systemPrompt":"%s"}}\n' \
            "$(command printf 'x%.0s' $(command seq 1 400))"
        command printf '{"type":"attachment","sessionId":"s1","timestamp":"2026-08-23T09:00:01.000Z","attachment":{"type":"hook_success","text":"noop"}}\n'
    } >"$mixed/proj/session.jsonl"

    run_ta attachments "$mixed"
    assert_equals "0" "$RC" "attachments reports on the mixed corpus"
    assert_contains "$OUT" "hook_success" \
        "an unexpected attachment type is surfaced, not filtered away"

    run_ta floor "$mixed"
    assert_equals "0" "$RC" "floor reports on the mixed corpus"
    assert_not_contains "$OUT" "hook_success" \
        "the floor vocabulary stays fixed so two measurements compare"
    assert_contains "$OUT" "prompt_snapshot" "and still carries the real floor components"
}

# --- Bash classification -----------------------------------------------------

test_bash_classification_resolves_subcommands_and_prefixes() {
    # Three ways the 49%/67% split goes wrong if classification is by head word
    # alone: `git log` and `git push` collapse together; `command grep` lands in
    # `other` (this repo's own scripts use that prefix everywhere); and a
    # pipeline whose tail writes reads as a pure read.
    local cls="$WORKDIR/classify"
    command mkdir -p "$cls/proj"
    {
        command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"k1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"k_a","name":"Bash","input":{"command":"git log --oneline"}},{"type":"tool_use","id":"k_b","name":"Bash","input":{"command":"git push origin main"}},{"type":"tool_use","id":"k_c","name":"Bash","input":{"command":"command grep -rn x ."}},{"type":"tool_use","id":"k_d","name":"Bash","input":{"command":"cat a | tee out.txt"}},{"type":"tool_use","id":"k_e","name":"Bash","input":{"command":"frobnicate --wild"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
    } >"$cls/proj/session.jsonl"

    run_ta bash-class "$cls"
    assert_equals "0" "$RC" "the classification corpus reports"
    # git log + command grep = 2 reads.
    assert_equals "2" "$(row_field "	read	" 4)" \
        "git log and a command-prefixed grep are reads"
    # git push + the tee pipeline = 2 mutations.
    assert_equals "2" "$(row_field "	mutate	" 4)" \
        "git push and a pipeline whose tail writes are mutations"
    # An unrecognized command is `other`, never folded into either side — an
    # unknown must not be able to move the ratio the finding quotes.
    assert_equals "1" "$(row_field "	other	" 4)" \
        "an unrecognized command is other, not silently a read"
}

# --- degradation and exit codes ----------------------------------------------

test_malformed_lines_are_tolerated() {
    # A transcript being written while this runs can end mid-line. One bad line
    # must not abandon the thousands of good ones — but it also must not be
    # counted, so the surviving figure is asserted rather than just the exit.
    local broken="$WORKDIR/broken"
    command mkdir -p "$broken/proj"
    {
        command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"b1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":42}}}\n'
        command printf '{"type":"assistant","truncated\n'
        command printf '\n'
    } >"$broken/proj/session.jsonl"
    run_ta growth "$broken"
    assert_equals "0" "$RC" "a truncated line does not abort the run"
    assert_equals "42" "$(decile_field 1 6)" "the good record is still counted exactly"
}

test_string_content_is_not_dropped() {
    # `content` may be a bare string rather than a block list. Returning [] for
    # that shape silently drops the turn — a wrong-but-quiet outcome.
    local strc="$WORKDIR/strcontent"
    command mkdir -p "$strc/proj"
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"s1","role":"assistant","model":"claude-opus-5","content":"plain text answer","usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":7}}}\n' \
        >"$strc/proj/session.jsonl"
    run_ta growth "$strc"
    assert_equals "0" "$RC" "a string-content turn reports"
    assert_equals "1" "$(decile_field 1 4)" "and is counted as a turn"
}

test_spawn_transcripts_are_excluded_from_main_session_reads() {
    # `debt` and `growth` size what the MAIN session absorbed. A subagent's
    # reading is precisely what a delegation keeps OUT of that context, so
    # counting it here would report the delegated volume as if the parent had
    # paid for it — inverting the conclusion the tool exists to support.
    run_ta growth "$CONTRACT"
    local turns
    turns="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{s += $4} END {print s+0}')"
    assert_equals "2" "$turns" "only the two main-session turns are counted"

    # And the spawn IS visible to the subcommand that asks about spawns.
    run_ta prefix "$CONTRACT"
    assert_equals "0" "$RC" "prefix reports on the spawn"
    assert_equals "1" "$(row_field "claude-opus-5" 3)" "the spawn is counted exactly once"
}

test_absent_root_exits_three() {
    run_ta debt "$WORKDIR/does-not-exist"
    assert_equals "3" "$RC" "an absent transcript root exits 3, not 0"
    assert_contains "$OUT" "no transcript root" "and names the cause"
}

test_empty_corpus_exits_three_not_zero() {
    # An empty corpus and a corpus that genuinely measured zero are DIFFERENT
    # claims, and only the second is evidence. Exit 3 keeps them distinguishable.
    local empty="$WORKDIR/empty"
    command mkdir -p "$empty/proj"
    run_ta growth "$empty"
    assert_equals "3" "$RC" "an empty corpus is an absent measurement, not a zero"
}

test_unknown_subcommand_exits_two() {
    run_ta dbet "$CONTRACT"
    assert_equals "2" "$RC" "an unknown subcommand exits 2"
}

test_every_subcommand_is_dispatchable() {
    # The argparse choices tuple and the SUBCOMMANDS dict are separate edits; a
    # subcommand added to one and not the other fails here rather than at use.
    local sub
    for sub in debt floor growth prefix bash-class attachments; do
        run_ta "$sub" "$CONTRACT"
        assert_true "[ $RC -ne 2 ]" "$sub is a registered subcommand"
    done
}

test_default_subcommand_is_debt() {
    set +e
    local out
    out="$(python3 "$TA_PY" --root "$CONTRACT" 2>&1)"
    set -e
    assert_contains "$out" "token-attribute debt" "the default subcommand is debt"
}

# --- the join contract: window scoping and per-model separation (review c1) --
#
# Review cycle 1 found the join this tool advertises did not work: window_start
# was min() over the WHOLE scanned corpus and model was the single most-common
# one, stamped onto every row. Under the documented usage (no --root, no window)
# that makes window_start the operator's oldest transcript — matching no gateway
# window — and silently attributes every other model's volume to the majority
# model. Both halves are fixed; these cases are what stop them coming back.

# Two models, two sessions, two days. Every property below needs all three axes:
# a single-model or single-day fixture cannot tell a collapse from a correct
# reading, which is exactly why the defect survived cycle 0.
MULTI="$WORKDIR/multi"
command mkdir -p "$MULTI/projA" "$MULTI/projB"
{
    command printf '{"type":"assistant","sessionId":"mA","timestamp":"2026-08-20T09:00:00.000Z","message":{"id":"ma1","role":"assistant","model":"model-alpha","content":[{"type":"tool_use","id":"m_a","name":"Bash","input":{"command":"grep -rn x ."}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":10}}}\n'
    command printf '{"type":"user","sessionId":"mA","timestamp":"2026-08-20T09:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"m_a","content":"%s"}]}}\n' \
        "$(command printf 'a%.0s' $(command seq 1 12000))"
} >"$MULTI/projA/session-a.jsonl"
{
    command printf '{"type":"assistant","sessionId":"mB","timestamp":"2026-08-25T09:00:00.000Z","message":{"id":"mb1","role":"assistant","model":"model-beta","content":[{"type":"tool_use","id":"m_b","name":"Read","input":{"file_path":"/x"}}],"usage":{"input_tokens":5,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":20}}}\n'
    command printf '{"type":"user","sessionId":"mB","timestamp":"2026-08-25T09:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"m_b","content":"%s"}]}}\n' \
        "$(command printf 'b%.0s' $(command seq 1 16000))"
} >"$MULTI/projB/session-b.jsonl"

test_models_are_not_collapsed_onto_the_majority() {
    # THE REGRESSION. Two models, each with its own tool and its own volume.
    # The old code emitted ONE model name for both rows; correct behavior keys
    # every row to the model of the turn that produced it.
    run_ta debt "$MULTI"
    assert_equals "0" "$RC" "the two-model corpus reports"

    local models
    models="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{print $2}' | command sort -u | command tr '\n' ' ')"
    assert_equals "model-alpha model-beta " "$models" \
        "each model appears as its own row, not collapsed onto the majority"
    # And the attribution is right, not merely plural: alpha issued the Bash
    # call, beta the Read. A row pairing a model with the other's tool would
    # satisfy the count above while still being wrong.
    assert_contains "$OUT" "model-alpha	Bash" "alpha keeps its own Bash call"
    assert_contains "$OUT" "model-beta	Read" "beta keeps its own Read call"
}

test_shares_are_within_a_model_not_across_the_scan() {
    # Each model contributed exactly one tool, so within-model shares are 100%
    # each. A cross-model denominator would print roughly 45/55 instead — making
    # one model's share depend on how much the OTHER model ran.
    run_ta debt "$MULTI"
    local alpha_share beta_share
    alpha_share="$(row_field "model-alpha	Bash" 7)"
    beta_share="$(row_field "model-beta	Read" 7)"
    assert_equals "100.0" "$alpha_share" "alpha's only tool is 100% of ALPHA's debt"
    assert_equals "100.0" "$beta_share" "beta's only tool is 100% of BETA's debt"
}

test_since_declares_the_window_start() {
    # The join key must be the DECLARED boundary, verbatim — that is the whole
    # point of the column. Not the earliest stamp that happens to fall inside it.
    run_ta debt "$MULTI" --since 2026-08-19T00:00:00Z --until 2026-08-26T00:00:00Z
    assert_equals "0" "$RC" "a scoped scan reports"
    local start
    start="$(row_field "model-alpha" 1)"
    assert_contains "$start" "2026-08-19T00:00:00" \
        "window_start is the declared --since, not the earliest stamp seen"
    assert_not_contains "$start" "2026-08-20" "the first in-window stamp is not the key"
}

test_window_excludes_out_of_range_turns() {
    # The filter must actually bite, or --since would be cosmetic: a key that
    # claims a window over data from outside it is the misattribution this
    # finding was about, just moved into the time axis.
    run_ta debt "$MULTI" --since 2026-08-24T00:00:00Z --until 2026-08-26T00:00:00Z
    assert_equals "0" "$RC" "a narrowed window reports"
    assert_contains "$OUT" "model-beta" "the in-window model is kept"
    assert_not_contains "$OUT" "model-alpha" "the out-of-window model is excluded"
}

test_unscoped_run_says_its_key_is_descriptive() {
    # An unscoped window_start joins against nothing. Silence would leave a
    # wrong number reading as right; the warning is the whole mitigation, and it
    # is a `#` comment so a consumer stripping /^#/ is unaffected.
    run_ta debt "$MULTI"
    assert_contains "$OUT" "# WARNING: no --since/--until" \
        "an unscoped run warns that its window_start is not a declared window"
    run_ta debt "$MULTI" --since 2026-08-19T00:00:00Z
    assert_not_contains "$OUT" "# WARNING: no --since" \
        "a scoped run does not warn"
}

test_bad_window_arguments_fail_loudly() {
    # --since is the knob that makes the join work; a typo in it must not
    # degrade to an unscoped scan that silently emits an unjoinable key.
    run_ta debt "$MULTI" --since not-a-date
    assert_equals "2" "$RC" "an unparseable --since exits 2"
    assert_contains "$OUT" "unparseable --since" "and names the offending flag"
    run_ta debt "$MULTI" --since 2026-08-25T00:00:00Z --until 2026-08-20T00:00:00Z
    assert_equals "2" "$RC" "an inverted window exits 2"
    assert_contains "$OUT" "selects nothing" "and says why it is empty"
}

# --- growth arithmetic: the headline ratio (review c1, deferrable) -----------
#
# Every earlier growth fixture had <= 2 turns, which with GROWTH_BUCKETS=10 puts
# every turn in decile 1 — so base == mean and growth_vs_first was trivially 1.0
# in every assertion that touched it. The bucketing and the ratio, i.e. the
# "3x" this subcommand exists to produce, were unverified. This corpus spans
# real deciles with a known escalation.
#
# 10 turns, input context 1000, 2000, ... 10000 -> one turn per decile, and
# decile 10's ratio over decile 1 is exactly 10.0.
GROWTH="$WORKDIR/growth"
command mkdir -p "$GROWTH/proj"
: >"$GROWTH/proj/session-g.jsonl"
_g=1
while [ "$_g" -le 10 ]; do
    command printf '{"type":"assistant","sessionId":"g1","timestamp":"2026-08-23T09:%02d:00.000Z","message":{"id":"g%s","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"t"}],"usage":{"input_tokens":0,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' \
        "$_g" "$_g" "$((_g * 1000))" >>"$GROWTH/proj/session-g.jsonl"
    _g=$((_g + 1))
done
unset _g

test_growth_ratio_is_computed_across_real_deciles() {
    # THE HEADLINE NUMBER. Ten turns, one per decile, escalating 1000..10000.
    run_ta growth "$GROWTH"
    assert_equals "0" "$RC" "the ten-turn corpus reports"

    # Decile 1 is the base: mean 1000, ratio 1.0.
    assert_equals "1000" "$(decile_field 1 5)" "decile 1's mean is its own input"
    assert_equals "1.0" "$(decile_field 1 8)" "decile 1 is the base, ratio 1.0"
    # Decile 10 is 10x it — the shape the #784 handoff threshold rests on.
    assert_equals "10000" "$(decile_field 10 5)" "decile 10's mean is exact"
    assert_equals "10.0" "$(decile_field 10 8)" "growth_vs_first is the real ratio"
    # A middle decile too: an off-by-one in `index * BUCKETS // total` that left
    # both ends right could still shift the interior.
    assert_equals "5.0" "$(decile_field 5 8)" "an interior decile is placed correctly"
    # Every decile has exactly one turn — nothing was dropped or double-placed.
    local placed
    placed="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{s += $4} END {print s+0}')"
    assert_equals "10" "$placed" "all ten turns are placed, each in its own decile"
}

test_empty_decile_is_a_sentinel_not_a_zero() {
    # With 2 turns over 10 buckets, 8 deciles hold no data. Emitting 0 for both
    # mean and ratio makes "no data" indistinguishable from "zero growth" in the
    # headline column — so an empty decile says `-`, the same spelling
    # window_start uses for an unknown value.
    run_ta growth "$THINK"
    assert_equals "0" "$RC" "a short corpus still reports"
    local empty_mean empty_ratio
    empty_mean="$(decile_field 9 5)"
    empty_ratio="$(decile_field 9 8)"
    assert_equals "-" "$empty_mean" "an empty decile's mean is the sentinel"
    assert_equals "-" "$empty_ratio" "an empty decile's ratio is the sentinel"
    assert_equals "0" "$(decile_field 9 4)" "and its turn count is a real zero"
}

# --- percentile arithmetic (review c1, deferrable) ---------------------------

test_percentile_does_not_collapse_p90_onto_the_maximum() {
    # _percentile carries a documented off-by-one hazard: `int(n * fraction)` is
    # one rank too high and at n=10 collapses p90 onto the MAXIMUM. A p90 equal
    # to the worst case reads as plausible, so the error hides — and every
    # earlier prefix fixture had ONE spawn, where median, p90 and max are the
    # same value and the formula is untestable by construction.
    local pctl="$WORKDIR/percentile"
    command mkdir -p "$pctl/proj/sess/subagents/wf"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        command printf '{"type":"assistant","sessionId":"p%s","timestamp":"2026-08-23T09:%02d:00.000Z","message":{"id":"p%s","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"s"}],"usage":{"input_tokens":0,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' \
            "$i" "$i" "$i" "$((i * 1000))" \
            >"$pctl/proj/sess/subagents/wf/agent-p$i.jsonl"
    done

    run_ta prefix "$pctl"
    assert_equals "0" "$RC" "the ten-spawn corpus reports"
    assert_equals "10" "$(row_field "claude-opus-5" 3)" "all ten spawns counted"
    # Nearest-rank over 1000..10000: median (p50) is rank 5 -> 5000.
    assert_equals "5000" "$(row_field "claude-opus-5" 4)" "median is nearest-rank, not an average"
    # p90 is rank 9 -> 9000. The off-by-one variant reports 10000 (the max).
    assert_equals "9000" "$(row_field "claude-opus-5" 5)" "p90 does not collapse onto the maximum"
    assert_equals "10000" "$(row_field "claude-opus-5" 7)" "the maximum is its own column"
    assert_equals "1000" "$(row_field "claude-opus-5" 6)" "and the minimum is exact"
}

# --- subcommand-resolved Bash classification (review c1, deferrable) ---------

test_gh_npm_and_ruff_subcommands_are_resolved() {
    # SUBCOMMAND_READ carries four heads; only `git` was covered. The others are
    # the same claim — `gh pr view` reads, `gh pr merge` does not — and an entry
    # no test exercises is indistinguishable from one that does not work.
    local subs="$WORKDIR/subcommands"
    command mkdir -p "$subs/proj"
    command printf '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"sc1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"s_a","name":"Bash","input":{"command":"gh pr view 12"}},{"type":"tool_use","id":"s_b","name":"Bash","input":{"command":"gh pr merge 12"}},{"type":"tool_use","id":"s_c","name":"Bash","input":{"command":"npm ls"}},{"type":"tool_use","id":"s_d","name":"Bash","input":{"command":"npm install left-pad"}},{"type":"tool_use","id":"s_e","name":"Bash","input":{"command":"ruff check ."}},{"type":"tool_use","id":"s_f","name":"Bash","input":{"command":"ruff format ."}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' \
        >"$subs/proj/session-s.jsonl"

    run_ta bash-class "$subs"
    assert_equals "0" "$RC" "the subcommand corpus reports"
    # Three reads (gh pr view, npm ls, ruff check) and three mutations
    # (gh pr merge, npm install, ruff format). Head-word-only classification
    # would put all six in one bucket.
    assert_equals "3" "$(row_field "	read	" 4)" "view/ls/check resolve as reads"
    assert_equals "3" "$(row_field "	mutate	" 4)" "merge/install/format resolve as mutations"
}

test_gh_noun_verb_is_resolved_on_the_verb() {
    # `gh` is NOUN-then-VERB, so the meaning is in the SECOND operand: an
    # earlier draft listed the nouns (`pr`, `issue`) as read subcommands and
    # classified `gh pr merge` — a remote state change — as investigation. That
    # inflates the read share the 49%/67% finding quotes, in the direction that
    # makes delegation look cheaper than it is.
    local ghf="$WORKDIR/gh-nounverb"
    command mkdir -p "$ghf/proj"
    command printf '{"type":"assistant","sessionId":"g1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"gh1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"g_a","name":"Bash","input":{"command":"gh pr view 12"}},{"type":"tool_use","id":"g_b","name":"Bash","input":{"command":"gh issue list"}},{"type":"tool_use","id":"g_c","name":"Bash","input":{"command":"gh pr merge 12 --squash"}},{"type":"tool_use","id":"g_d","name":"Bash","input":{"command":"gh pr create --fill"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' \
        >"$ghf/proj/session-gh.jsonl"

    run_ta bash-class "$ghf"
    assert_equals "0" "$RC" "the gh corpus reports"
    # Same noun (`pr`), opposite verdicts — which is the whole point: a
    # classifier keying on the noun cannot produce this split at all.
    assert_equals "2" "$(row_field "	read	" 4)" "gh pr view / gh issue list are reads"
    assert_equals "2" "$(row_field "	mutate	" 4)" "gh pr merge / gh pr create are mutations"
}

# --- cycle-2 findings: the two arms no earlier fixture reached -------------

test_until_without_since_is_rejected() {
    # CYCLE 2, BLOCKING. `Window.declared` is true for EITHER boundary (it gates
    # the warning), but only --since supplies a verbatim window_start. So
    # `--until` alone suppressed the warning AND fell back to the earliest stamp
    # seen — a key that silently claims to be a real join key, which is exactly
    # the shape cycle 1 was filed to eliminate. Every existing --until fixture
    # pairs it with --since, so nothing reached this arm.
    run_ta debt "$MULTI" --until 2026-08-26T00:00:00Z
    assert_equals "2" "$RC" "--until without --since is a usage error, not a half-window"
    assert_contains "$OUT" "needs a --since" "and says what is missing"
    # The failure it replaces: exit 0, no warning, descriptive key.
    assert_not_contains "$OUT" "window_start	model" "it emits no table at all"
}

test_value_taking_flags_do_not_eat_the_subcommand() {
    # CYCLE 2, BLOCKING. The operand scan filtered flags but not their VALUES,
    # so `git -C some/dir log` left `some/dir` as the first operand, matched no
    # read subcommand, and classified a log as a MUTATION. This repo's own
    # scripts use `-C` constantly, so the miscount lands on the read share in
    # the direction that UNDERSTATES investigation.
    #
    # ONE CASE PER VALUE_FLAGS HEAD, which is the point of the list below.
    # Cycle 3 caught this comment claiming `npm -w` coverage the fixture did not
    # have — the exact comment-asserts-intent-not-code shape this repo records.
    # A typo'd `npm`/`ruff` entry (`--Workspace`, say) would have been invisible:
    # the generic startswith("-") filter absorbs an unmatched flag, so the row
    # still lands in `read` and nothing fails. Every head is exercised here now,
    # in both the separate-value and inline-value spellings.
    local vf="$WORKDIR/valueflags"
    command mkdir -p "$vf/proj"
    command printf '{"type":"assistant","sessionId":"v1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"vf1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"v_a","name":"Bash","input":{"command":"git -C some/dir log --oneline"}},{"type":"tool_use","id":"v_b","name":"Bash","input":{"command":"gh -R owner/repo pr view 1"}},{"type":"tool_use","id":"v_c","name":"Bash","input":{"command":"git --git-dir=/tmp/.git log"}},{"type":"tool_use","id":"v_e","name":"Bash","input":{"command":"npm -w pkg ls"}},{"type":"tool_use","id":"v_f","name":"Bash","input":{"command":"npm --prefix /tmp ls"}},{"type":"tool_use","id":"v_g","name":"Bash","input":{"command":"ruff --config pyproject.toml check ."}},{"type":"tool_use","id":"v_d","name":"Bash","input":{"command":"git -C /tmp push origin main"}},{"type":"tool_use","id":"v_h","name":"Bash","input":{"command":"npm -w pkg install left-pad"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' \
        >"$vf/proj/session-v.jsonl"

    run_ta bash-class "$vf"
    assert_equals "0" "$RC" "the value-flag corpus reports"
    # Six reads, one per VALUE_FLAGS head in both spellings: the flag's value
    # must not be mistaken for the subcommand, whether separate (`-C dir`,
    # `-R owner/repo`, `-w pkg`, `--prefix /tmp`, `--config f`) or inline
    # (`--git-dir=`).
    assert_equals "6" "$(row_field "	read	" 4)" \
        "a flag's value is skipped, not read as the subcommand"
    # And the guard must not over-consume: `git -C /tmp push` and
    # `npm -w pkg install` are still mutations, so skipping cannot have
    # swallowed the real verb. Asserted per head, since over-consumption would
    # be a per-entry bug.
    assert_equals "2" "$(row_field "	mutate	" 4)" \
        "skipping a flag value does not swallow the real subcommand"
}

test_prefix_honours_the_window() {
    # CYCLE 2, deferrable-but-cheap. cmd_prefix filters with a `break` on the
    # first billed turn rather than the shared list comprehension every other
    # report uses, and no fixture passed --since to `prefix` — so its window
    # arm was the one structurally-different filter with no coverage.
    local pw="$WORKDIR/prefix-window"
    command mkdir -p "$pw/proj/sess/subagents/wf"
    command printf '{"type":"assistant","sessionId":"o1","timestamp":"2026-08-20T09:00:00.000Z","message":{"id":"pw1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"old"}],"usage":{"input_tokens":2,"cache_read_input_tokens":11000,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' \
        >"$pw/proj/sess/subagents/wf/agent-old.jsonl"
    command printf '{"type":"assistant","sessionId":"n1","timestamp":"2026-08-25T09:00:00.000Z","message":{"id":"pw2","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"new"}],"usage":{"input_tokens":2,"cache_read_input_tokens":22000,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' \
        >"$pw/proj/sess/subagents/wf/agent-new.jsonl"

    run_ta prefix "$pw" --since 2026-08-24T00:00:00Z --until 2026-08-26T00:00:00Z
    assert_equals "0" "$RC" "a windowed prefix run reports"
    assert_equals "1" "$(row_field "claude-opus-5" 3)" \
        "only the in-window spawn is counted"
    # The in-window spawn is the 22002-token one; counting the out-of-window one
    # would move this number, so it pins WHICH spawn survived rather than merely
    # how many.
    assert_equals "22002" "$(row_field "claude-opus-5" 4)" \
        "and it is the in-window spawn, not the older one"
    # Both spawns unscoped, so the filter is what excluded it — not the corpus.
    run_ta prefix "$pw"
    assert_equals "2" "$(row_field "claude-opus-5" 3)" \
        "both spawns are present when no window is declared"
}

test_tab_in_model_field_cannot_shift_columns() {
    # _tsv_safe's docstring names THREE verbatim, untrusted columns it protects
    # — `model`, a tool `name`, and attachments' open type vocabulary — but only
    # the third was pinned. `model` is the join key's second column, so a tab
    # there shifts every field after it while the row still looks well-formed.
    # Cycle 3 flagged the gap; this closes it on the column that carries the
    # join.
    local mt="$WORKDIR/model-tab"
    command mkdir -p "$mt/proj"
    command printf '{"type":"assistant","sessionId":"m1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"mt1","role":"assistant","model":"evil\\tmodel","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' \
        >"$mt/proj/session-m.jsonl"

    run_ta growth "$mt"
    assert_equals "0" "$RC" "a tab-bearing model reports"
    local widths
    widths="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{print NF}' | command sort -u | command tr '\n' ' ')"
    assert_equals "8 " "$widths" "the embedded tab does not add a column"
    assert_contains "$OUT" "evil model" "and the model survives with the tab neutralized"
}

test_tab_in_tool_name_cannot_shift_columns() {
    # The THIRD column _tsv_safe's docstring commits to protecting. A tool
    # `name` is read straight from a tool_use block with no vocabulary
    # restriction — an MCP server registers whatever name it likes — so it is
    # the least controlled of the three. Cycles 3 and 4 closed `model` and the
    # attachment type; this completes the set, so the docstring's claim is true
    # of all three rather than of two.
    local tn="$WORKDIR/tool-name-tab"
    command mkdir -p "$tn/proj"
    {
        command printf '{"type":"assistant","sessionId":"tn1","timestamp":"2026-08-23T09:00:00.000Z","message":{"id":"tn1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tn_a","name":"evil\\ttool","input":{}}],"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
        command printf '{"type":"user","sessionId":"tn1","timestamp":"2026-08-23T09:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tn_a","content":"%s"}]}}\n' \
            "$(command printf 'q%.0s' $(command seq 1 12000))"
    } >"$tn/proj/session-tn.jsonl"

    run_ta debt "$tn"
    assert_equals "0" "$RC" "a tab-bearing tool name reports"
    local widths
    widths="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{print NF}' | command sort -u | command tr '\n' ' ')"
    assert_equals "7 " "$widths" "the embedded tab does not add a column"
    assert_contains "$OUT" "evil tool" "and the tool name survives, tab neutralized"
}

test_tab_bearing_field_cannot_shift_columns() {
    # The join is POSITIONAL, and `attachments`' vocabulary is deliberately OPEN
    # — the type string comes straight from transcript JSON. A tab in it splits
    # the row, so every later column is read as a different field and the row
    # still looks well-formed. Escaping is centralized in emit(); this pins it.
    local tabf="$WORKDIR/tabfield"
    command mkdir -p "$tabf/proj"
    {
        command printf '{"type":"attachment","sessionId":"t1","timestamp":"2026-08-23T09:00:00.000Z","attachment":{"type":"evil\\tname","text":"x"}}\n'
        # A billed turn too: cmd_attachments walks turns, so an attachment-only
        # transcript takes the exit-3 arm and never reaches the escaping.
        command printf '{"type":"assistant","sessionId":"t1","timestamp":"2026-08-23T09:00:01.000Z","message":{"id":"t1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":5}}}\n'
    } >"$tabf/proj/session-t.jsonl"

    run_ta attachments "$tabf"
    assert_equals "0" "$RC" "a tab-bearing attachment type reports"
    # Every row must have exactly the declared number of columns.
    local widths
    widths="$(command printf '%s\n' "$OUT" | command grep -v '^#' |
        command awk -F'\t' '{print NF}' | command sort -u | command tr '\n' ' ')"
    assert_equals "7 " "$widths" "the embedded tab does not add a column"
    assert_contains "$OUT" "evil name" "and the value survives with the tab neutralized"
}

# --- the suite's own validity (third-instance guard) ------------------------

test_every_fixture_payload_is_valid_json() {
    # THE TRAP THIS SUITE KEEPS HITTING, now a test instead of vigilance.
    #
    # A fixture line written with a RAW control character (`\t` rather than
    # `\\t` inside a single-quoted printf) is INVALID JSON. _iter_records skips
    # an unparseable line by design — correctly, since a transcript being
    # written can end mid-line — so the fixture silently carries nothing and the
    # test passes while never reaching its subject. That is a vacuous test: the
    # exact "silence reads as a pass" shape this repo keeps filing issues about.
    #
    # Measured three times in this suite's own history (the escaping fixture,
    # then the model-field fixture, then this guard's own first draft), which is
    # why it is checked rather than remembered.
    #
    # Reads THIS file's printf payloads and parses each. Payloads carrying a `%`
    # substitution are assembled at runtime from shell variables, so they cannot
    # be parsed standalone and are skipped; the deliberately-truncated
    # malformed-line fixture is expected to be invalid and is exempted by name.
    local bad
    bad="$(
        python3 - "$SUITE_FILE" <<'PYEOF'
import json, re, subprocess, sys

src = open(sys.argv[1]).read()
bad = 0
for payload in re.findall(r"command printf '(\{[^']*)'", src):
    # A payload carrying %s/%02d is assembled at runtime from shell variables.
    # Skipping those would leave 11 of 41 unchecked — a blind spot inside the
    # very guard written to remove one — so feed printf placeholder arguments
    # instead. The substituted VALUE is irrelevant here; what is being checked
    # is that the surrounding literal carries no raw control character.
    slots = payload.count("%") - 2 * payload.count("%%")
    args = ["1"] * max(0, slots)
    rendered = subprocess.run(
        ["printf", payload, *args], capture_output=True, text=True
    ).stdout
    for line in rendered.splitlines():
        if not line.strip() or "truncated" in line:
            continue
        try:
            json.loads(line)
        except ValueError as exc:
            bad += 1
            print(f"{line[:80]} -> {exc}")
print(f"COUNT={bad}")
PYEOF
    )"
    assert_contains "$bad" "COUNT=0" \
        "every fixture payload is valid JSON (a raw tab makes one vacuous)"
}

# --- the shim's 77 sentinel --------------------------------------------------

test_shim_reports_77_without_python() {
    # The shim must exit the reserved 77 sentinel, never 0, when its runtime is
    # missing — reporting nothing beats reporting wrong attribution.
    #
    # Forcing python3 absent needs BOTH an emptied PATH and BASH_ENV unset:
    # /etc/bash_env re-seeds PATH in every non-interactive bash here, so a
    # PATH-only override silently leaves python3 findable and the test proves
    # nothing (a measured trap — see the sibling gate).
    local runner="$WORKDIR/no-python.sh" out rc
    {
        command printf '#!/usr/bin/env bash\n'
        # Resolve bash BEFORE emptying PATH: the fixture removes python3, not
        # the shell, and an unresolvable interpreter would fail as 127 for a
        # reason that has nothing to do with the sentinel under test.
        command printf '_sh="$(command -v bash)"\n'
        command printf 'export PATH=%s/empty-bin\n' "$WORKDIR"
        command printf 'unset BASH_ENV\n'
        command printf 'exec "$_sh" "$1" debt\n'
    } >"$runner"
    command mkdir -p "$WORKDIR/empty-bin"
    set +e
    out="$(command bash "$runner" "$TA_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "an absent python3 exits the 77 sentinel"
    assert_contains "$out" "python3 not found" "and names the real cause"
}

test_shim_reports_77_on_old_python() {
    # A PRESENT but too-old interpreter is a different branch from an absent
    # one, and the absent-python test cannot reach it. The stub satisfies
    # `command -v` and fails the version probe.
    local stub_dir="$WORKDIR/oldpy" runner="$WORKDIR/old-python.sh" out rc
    command mkdir -p "$stub_dir"
    {
        command printf '#!/usr/bin/env sh\n'
        command printf 'exit 1\n'
    } >"$stub_dir/python3"
    command chmod +x "$stub_dir/python3"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'export PATH=%s:/usr/bin:/bin\n' "$stub_dir"
        command printf 'unset BASH_ENV\n'
        command printf 'exec bash "$1" debt\n'
    } >"$runner"
    set +e
    out="$(command bash "$runner" "$TA_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "a too-old python3 exits the 77 sentinel"
    assert_contains "$out" "older than 3.11" "and names the version as the cause"
}

test_shim_diagnoses_a_missing_tool_correctly() {
    # A missing .py and a missing python3 both exit 77 but need DIFFERENT
    # messages: the operator action is "reinstall the plugin" versus "install
    # python". One message for both would send them down the wrong path.
    local fake="$WORKDIR/fakedir" out rc
    command mkdir -p "$fake"
    command cp "$TA_SH" "$fake/token-attribute.sh"
    set +e
    out="$(command bash "$fake/token-attribute.sh" debt 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "a missing .py exits the 77 sentinel"
    assert_contains "$out" "plugin install is incomplete" \
        "and diagnoses the install, not the runtime"
}

# --- the decision the issue asked to be recorded (AC8) -----------------------

test_bash_fallback_decision_is_recorded() {
    # #788 AC8: "the bash-fallback decision is recorded with its reason" — and
    # asks for it to be STATED rather than defaulted either way. A reader
    # reaching for a .sh twin must find the reason there is none, in the two
    # files they would open.
    assert_file_contains "$TA_SH" "BASH-FALLBACK DECISION" \
        "the shim states the decision under a findable heading"
    assert_file_contains "$TA_SH" "pre-scan family" \
        "and distinguishes this tool from the family that keeps one"
    assert_file_contains "$TA_PY" "NO bash fallback" \
        "the tool's own header states it too"
    # The 77 sentinel is half the decision: having chosen not to degrade, the
    # tool must refuse loudly. A shim that exited 0 here would make the recorded
    # reason false in practice.
    assert_file_contains "$TA_SH" "exit 77" \
        "and the refusal path the decision implies is present"
}

run_test test_union_beats_any_single_line "TRAP 2: blocks are unioned across duplicate message.id lines"
run_test test_usage_is_not_summed_per_line "TRAP 1: usage is read once per id, not summed per line"
run_test test_thinking_tokens_come_from_usage_not_content "TRAP 3: thinking tokens come from usage, not content"
run_test test_thinking_is_not_derived_from_block_text "TRAP 3: thinking is its own field, not output_tokens"
run_test test_naive_timestamp_is_normalized_to_utc "TRAP 4: a naive stamp is normalized to UTC"
run_test test_same_instant_reads_identically_under_either_spelling "TRAP 4: an aware stamp is not double-shifted"
run_test test_unknown_timezone_fails_loudly "TRAP 4: an unknown --tz fails loudly"
run_test test_every_subcommand_emits_the_join_key "AC6: every subcommand emits the window_start+model join key"
run_test test_rows_are_tab_separated_with_no_empty_fields "AC6: no row carries a column-shifting empty field"
run_test test_absent_timestamp_emits_a_sentinel_not_a_blank "AC6: an unknown window_start is a sentinel"
run_test test_debt_is_size_times_residency_not_size "debt ranks by residency product, not by size"
run_test test_trivial_results_are_floored_out "trivial results are floored out of the debt table"
run_test test_floor_vocabulary_is_fixed_and_attachments_is_open "floor is fixed vocabulary, attachments is open"
run_test test_bash_classification_resolves_subcommands_and_prefixes "Bash classification resolves subcommands and prefixes"
run_test test_malformed_lines_are_tolerated "a truncated line is tolerated, not counted"
run_test test_string_content_is_not_dropped "string-shaped content is not dropped"
run_test test_spawn_transcripts_are_excluded_from_main_session_reads "spawn transcripts stay out of main-session totals"
run_test test_absent_root_exits_three "an absent transcript root exits 3"
run_test test_empty_corpus_exits_three_not_zero "an empty corpus exits 3, not a measured zero"
run_test test_unknown_subcommand_exits_two "an unknown subcommand exits 2"
run_test test_every_subcommand_is_dispatchable "every declared subcommand is dispatchable"
run_test test_default_subcommand_is_debt "the default subcommand is debt"
run_test test_models_are_not_collapsed_onto_the_majority "JOIN: each model keeps its own rows (review c1)"
run_test test_shares_are_within_a_model_not_across_the_scan "JOIN: shares are within a model, not across the scan"
run_test test_since_declares_the_window_start "JOIN: --since becomes the emitted window_start"
run_test test_window_excludes_out_of_range_turns "JOIN: the window filter actually excludes"
run_test test_unscoped_run_says_its_key_is_descriptive "JOIN: an unscoped run warns its key is descriptive"
run_test test_bad_window_arguments_fail_loudly "JOIN: a bad window fails loudly, never silently unscoped"
run_test test_growth_ratio_is_computed_across_real_deciles "growth_vs_first is exact across ten real deciles"
run_test test_empty_decile_is_a_sentinel_not_a_zero "an empty decile is a sentinel, not a zero"
run_test test_percentile_does_not_collapse_p90_onto_the_maximum "p90 does not collapse onto the maximum at n=10"
run_test test_gh_npm_and_ruff_subcommands_are_resolved "gh/npm/ruff subcommands resolve read vs mutate"
run_test test_gh_noun_verb_is_resolved_on_the_verb "gh noun-verb resolves on the VERB, not the noun"
run_test test_until_without_since_is_rejected "--until without --since is rejected (cycle 2)"
run_test test_value_taking_flags_do_not_eat_the_subcommand "a flag value is not read as the subcommand (cycle 2)"
run_test test_prefix_honours_the_window "prefix honours --since/--until (cycle 2)"
run_test test_tab_in_model_field_cannot_shift_columns "an embedded tab in MODEL cannot shift columns"
run_test test_tab_in_tool_name_cannot_shift_columns "an embedded tab in TOOL NAME cannot shift columns"
run_test test_tab_bearing_field_cannot_shift_columns "an embedded tab cannot shift TSV columns"
run_test test_every_fixture_payload_is_valid_json "every fixture payload is valid JSON (no vacuous fixture)"
run_test test_shim_reports_77_without_python "the shim exits 77 when python3 is absent"
run_test test_shim_reports_77_on_old_python "the shim exits 77 when python3 is too old"
run_test test_shim_diagnoses_a_missing_tool_correctly "the shim diagnoses a missing .py distinctly"
run_test test_bash_fallback_decision_is_recorded "AC8: the bash-fallback decision is recorded with its reason"

generate_report
