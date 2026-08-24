#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/context-budget.sh (issue #784).
#
# The script reports a session's CURRENT context size and an ok/advise/handoff
# verdict, and it is the signal the golem handoff policy acts on. Two properties
# carry most of the risk, and most of the cases below exist for one of them:
#
#   1. IT IS A POINT READING, NOT A SUM. golem-token-scrape.sh sums across the
#      transcript; this reads the LAST top-level record. The two are opposite
#      contracts over the same file, and a summing regression still emits a
#      plausible-looking token count — so every fixture is built so that the sum
#      and the correct answer DIFFER, and several are built so a regression
#      lands in a different VERDICT (the loudest possible failure). A fixture
#      whose sum equals its last record would pass under both implementations
#      and pin nothing (the escaped-fixture-cannot-self-match class).
#
#   2. IT MUST FAIL LOUD, NEVER RETURN A SILENT 0. A bogus low reading is worse
#      than no reading: it reports "plenty of headroom" for a session that is
#      actually at 400k, silently suppressing a handoff that is due. Every
#      unreadable-input path is asserted to exit non-zero with a message.
#
# The verdict boundaries are tested AT the boundary (>= threshold, >= 80%), not
# comfortably inside the bands, because an off-by-one in the comparison is the
# regression a mid-band fixture cannot see.
#
# Pure bash + coreutils via the `command` builtin. Uses the shared harness
# assertions and the golem sandbox plumbing. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CTX_BUDGET="$REPO_ROOT/plugins/workflow/scripts/context-budget.sh"
CONFIG_SH="$REPO_ROOT/plugins/workflow/scripts/config.sh"

# Both are read by the sourced sandbox library rather than by this file, and are
# defined the same way validate-golem-scripts.sh defines them for its fragments.
# shellcheck disable=SC2034  # consumed by tests/lib/golem-sandbox.sh
{
    # Resolve the real bash once so child invocations work even when PATH is
    # deliberately stripped (the no-jq cases).
    REAL_BASH="$(command -v bash)"

    # Git's hook-exported environment — scrub per invocation so each sandbox is
    # hermetic even under a pre-push hook.
    GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/golem-sandbox.sh
source "$SCRIPT_DIR/lib/golem-sandbox.sh"

test_suite "context-budget.sh (#784)"

jq_missing() { ! command -v jq >/dev/null 2>&1; }

# --- the point-reading contract ---------------------------------------------

# The headline case. The fixture's last top-level record is 160000; a naive sum
# over all records is 1120000 and a top-level-only sum is 220000. Asserting the
# exact 160000 rejects both.
test_reads_last_toplevel_record_not_a_sum() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_ADVISE"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a planted transcript reads cleanly"
    assert_contains "$RUN_OUT" "context_tokens=160000" \
        "reads the LAST top-level record (10000+140000+10000), not a sum"
    assert_not_contains "$RUN_OUT" "context_tokens=1120000" \
        "does not sum every record (the naive-sum regression)"
    assert_not_contains "$RUN_OUT" "context_tokens=220000" \
        "does not sum top-level records either (the scrape-contract regression)"
}

# The last record is SMALLER than an earlier one, so a max/first/sum regression
# inverts the verdict from ok to handoff rather than merely shifting a number.
test_a_smaller_last_record_wins() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_OK"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_contains "$RUN_OUT" "context_tokens=20000" \
        "the LAST record wins even when an earlier one is much larger"
    assert_contains "$RUN_OUT" "verdict=ok" \
        "a shrinking session reads ok — a first/max/sum regression would say handoff"
}

# Sub-workflow (isSidechain) records are another session's context, not this
# one's. The fixture's sidechain record is 900000 — far past threshold — so a
# leak would flip the verdict to handoff.
test_excludes_sidechain_records() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_ADVISE"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_not_contains "$RUN_OUT" "context_tokens=900000" \
        "a sub-workflow's context is excluded"
    assert_contains "$RUN_OUT" "verdict=advise" \
        "the sub-workflow's 900000 does not flip the verdict to handoff"
}

# The real on-disk tail is a `{"type":"summary"}` record with no usage. Reading
# `.[-1]` blindly instead of the last USAGE-bearing record finds nothing and
# would wrongly exit 2. Every fixture carries that tail; this names the reason.
test_ignores_a_trailing_usageless_record() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a trailing summary record does not defeat the read"
    assert_contains "$RUN_OUT" "context_tokens=200100" "reads past the usage-less tail"
}

# A partial trailing line is expected when a session is captured mid-write.
test_skips_a_malformed_trailing_line() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_PARTIAL"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a mid-write partial line does not fail the parse"
    assert_contains "$RUN_OUT" "context_tokens=150000" "reads the last COMPLETE record"
}

# --- verdict boundaries ------------------------------------------------------

# AT the threshold, not past it: `>=` vs `>` is the off-by-one this pins.
test_verdict_handoff_at_exactly_the_threshold() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=200100
    assert_contains "$RUN_OUT" "verdict=handoff" "context == threshold is handoff, not advise"
    assert_contains "$RUN_OUT" "pct_of_threshold=100" "renders exactly 100%"
}

# One token below the threshold must NOT be handoff.
test_verdict_advise_one_below_the_threshold() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=200101
    assert_contains "$RUN_OUT" "verdict=advise" "one token short of the threshold is not a handoff"
}

# The advisory band opens at exactly 80%.
test_verdict_advise_at_exactly_eighty_percent() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    # 200100 is exactly 80% of 250125.
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=250125
    assert_contains "$RUN_OUT" "verdict=advise" "80% of threshold enters the advisory band"
}

# Just below the band is ok — the other side of the same boundary.
test_verdict_ok_just_below_the_advisory_band() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    # 80% of 250130 is 200104, so 200100 sits just under the band.
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=250130
    assert_contains "$RUN_OUT" "verdict=ok" "just below 80% is ok, not advise"
}

# --- fail-loud paths ---------------------------------------------------------

test_missing_transcript_dir_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "no transcript dir exits 2, never a silent 0"
    assert_contains "$RUN_OUT" "no transcript dir" "names the missing transcript"
    assert_not_contains "$RUN_OUT" "context_tokens=0" \
        "does NOT emit a zero reading (which would read as plenty of headroom)"
}

# A transcript that exists but holds no top-level reading. This is where the
# point-reading contract diverges from the scrape's: for a SUM, "nothing yet" is
# a real 0; for a POINT reading it is an unknown, and must fail loud.
test_no_toplevel_record_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_NO_TOPLEVEL"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "a transcript with no top-level record exits 2"
    assert_not_contains "$RUN_OUT" "verdict=ok" \
        "absence must not be reported as a healthy budget"
}

test_no_subcommand_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$CTX_BUDGET" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "no arguments is a usage error"
    assert_contains "$RUN_OUT" "usage:" "prints usage"
}

test_unknown_subcommand_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$CTX_BUDGET" bogus "$sb" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "an unknown subcommand is a usage error, not a silent check"
}

# A non-numeric knob must fail loud rather than reach `[ ... -ge ... ]`, where a
# string operand is an "integer expression expected" error that would misclassify
# the verdict.
test_non_numeric_threshold_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=175k
    assert_exit 1 "$RUN_RC" "a non-numeric threshold exits 1"
    assert_contains "$RUN_OUT" "must be a positive integer" "names the offending knob"
    assert_not_contains "$RUN_OUT" "verdict=" "emits no verdict on a bad knob"
}

# A LEADING-ZERO knob is all digits, so a digits-only guard passes it — and then
# `$(())` reads it as octal while `[ -ge ]` reads it as decimal. Two arms, both
# reproduced against the pre-fix script, both regressions this pins:
#
#   0400000 -> emitted `pct_of_threshold=231` beside `verdict=advise`. The two
#   outputs of a single run CONTRADICTED each other, and a caller reading the
#   verdict alone would silently skip a handoff that was due — the exact
#   "plausible-looking wrong number" this script's fail-loud contract forbids.
test_leading_zero_octal_threshold_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=0400000
    assert_exit 1 "$RUN_RC" "a leading-zero (octal-parsed) threshold exits 1"
    assert_contains "$RUN_OUT" "no leading zeros" "names the leading-zero rule"
    assert_not_contains "$RUN_OUT" "verdict=" "emits no verdict on an octal-ambiguous knob"
    assert_not_contains "$RUN_OUT" "pct_of_threshold=" \
        "emits no percent either — the contradictory pct/verdict pair is the bug"
}

# The other arm: a leading-zero value containing 8 or 9 is an INVALID octal
# literal, so `$(())` errored twice and the script died on `pct: unbound
# variable` under `set -u` — a crash instead of an actionable message.
test_invalid_octal_threshold_fails_loud_not_crash() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=089000
    assert_exit 1 "$RUN_RC" "an invalid-octal threshold exits 1"
    assert_contains "$RUN_OUT" "no leading zeros" "prints the actionable message"
    assert_not_contains "$RUN_OUT" "unbound variable" "does not crash under set -u"
    assert_not_contains "$RUN_OUT" "value too great for base" \
        "does not leak a raw bash arithmetic error"
}

# The floor knob takes the same guard — the harden-one-knob-grep-every-sibling
# class: fixing the threshold and leaving its sibling exposed is the recurring
# defect this repo has recorded, so both knobs are pinned.
test_leading_zero_floor_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_FLOOR=091000
    assert_exit 1 "$RUN_RC" "a leading-zero floor exits 1 too, not just the threshold"
    assert_contains "$RUN_OUT" "CONTEXT_BUDGET_FLOOR" "names the offending knob"
}

# A zero threshold would divide by zero in the percent computation.
test_zero_threshold_fails_loud() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" CONTEXT_BUDGET_THRESHOLD=0
    assert_exit 1 "$RUN_RC" "a zero threshold exits 1 rather than dividing by zero"
}

# The documented exit 3 (jq absent). Every other case in this file SKIPS when jq
# is missing, so without this one the no-jq branch is covered only in an
# environment that happens to lack jq — where every sibling case skips too and the
# suite goes dark rather than testing it. That is the
# self-skipping-test-hides-the-risky-branch class: skip-if-tool-absent covers only
# the present arm. So FORCE the absence instead, with jq genuinely installed:
# stub a bash-only PATH (BASH_ENV unset so /etc/bash_env cannot restore it),
# mirroring gate_age_unit's nojq mode.
test_missing_jq_exits_3() {
    if jq_missing; then
        skip_test "jq genuinely absent — this case must force absence, not observe it"
        return 0
    fi
    local sb stub
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    stub="$sb/stub-bin"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$stub" HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$CTX_BUDGET" check "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "an absent jq exits 3, its own documented code"
    assert_contains "$RUN_OUT" "jq not found on PATH" "names the missing tool"
    assert_not_contains "$RUN_OUT" "verdict=" \
        "emits no verdict — an unparsable transcript is not a healthy budget"
}

# --- knobs + drift guard -----------------------------------------------------

test_threshold_and_floor_are_env_overridable() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_OK"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42" \
        CONTEXT_BUDGET_THRESHOLD=10000 CONTEXT_BUDGET_FLOOR=1234
    assert_contains "$RUN_OUT" "threshold=10000" "the threshold knob is honored"
    assert_contains "$RUN_OUT" "floor=1234" "the floor knob is honored"
    assert_contains "$RUN_OUT" "verdict=handoff" \
        "a lowered threshold re-classifies the same transcript"
}

test_emits_the_documented_default_threshold_and_floor() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_OK"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_contains "$RUN_OUT" "threshold=175000" "the derived default threshold"
    assert_contains "$RUN_OUT" "floor=91000" "the measured default floor"
}

# config.sh's comment claims the two knobs must be EXPORTED because the consumer
# is reached as a subprocess. Nothing tested that claim: run_ctx_budget passes the
# vars straight into the child's environment, which works whether or not config.sh
# exports them — so dropping the `export` would leave every other case green while
# an operator's override silently reverted to the child's inlined defaults.
#
# This drives the real path: set the var, SOURCE config.sh, then invoke
# context-budget.sh as a plain child with no per-invocation env assignment. Only a
# genuine `export` carries the value across that boundary.
test_config_export_propagates_to_the_subprocess() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    # The override is set as a SHELL variable inside the child, NOT as an env
    # prefix on the invocation. That distinction is the whole test: a var passed
    # as `VAR=x cmd` is already in cmd's environment and propagates to
    # grandchildren whether or not config.sh exports it — so an env-prefix
    # version of this test passes with the `export` line deleted, which a
    # mutation round caught. Assigning it as a plain shell variable means only
    # config.sh's own `export` can carry it across the subprocess boundary.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" -c 'CONTEXT_BUDGET_THRESHOLD=999999; . "$1"; "$2" check "$3"' \
            _ "$CONFIG_SH" "$CTX_BUDGET" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "the sourced-config subprocess call succeeds"
    assert_contains "$RUN_OUT" "threshold=999999" \
        "the override crosses the subprocess boundary — proves the export"
    assert_not_contains "$RUN_OUT" "threshold=175000" \
        "the child did NOT fall back to its own inlined default"
    assert_contains "$RUN_OUT" "verdict=ok" \
        "and the propagated value actually drove the verdict"
}

# context-budget.sh inlines its defaults so it runs standalone; config.sh also
# declares them for the scripts that source it. Two copies of a number drift, so
# pin them equal — the same guard golem-notify.sh's inlined sink defaults carry.
test_defaults_match_config_sh() {
    local script_threshold script_floor cfg_threshold cfg_floor
    script_threshold="$(command sed -n 's/^: "${CONTEXT_BUDGET_THRESHOLD:=\([0-9]*\)}"$/\1/p' "$CTX_BUDGET")"
    script_floor="$(command sed -n 's/^: "${CONTEXT_BUDGET_FLOOR:=\([0-9]*\)}"$/\1/p' "$CTX_BUDGET")"
    cfg_threshold="$(command sed -n 's/^: "${CONTEXT_BUDGET_THRESHOLD:=\([0-9]*\)}"$/\1/p' "$CONFIG_SH")"
    cfg_floor="$(command sed -n 's/^: "${CONTEXT_BUDGET_FLOOR:=\([0-9]*\)}"$/\1/p' "$CONFIG_SH")"
    assert_not_empty "$script_threshold" "context-budget.sh declares a threshold default"
    assert_not_empty "$cfg_threshold" "config.sh declares a threshold default"
    assert_equals "$script_threshold" "$cfg_threshold" "threshold defaults agree across the two files"
    assert_not_empty "$script_floor" "context-budget.sh declares a floor default"
    assert_not_empty "$cfg_floor" "config.sh declares a floor default"
    assert_equals "$script_floor" "$cfg_floor" "floor defaults agree across the two files"
}

# The newest-mtime session is the active one. After a handoff the fresh session
# is a NEW file, so reading the newest is what makes the size drop back to the
# floor; reading an older one would re-trigger a handoff that already happened.
test_reads_the_newest_session_transcript() {
    if jq_missing; then
        skip_test "jq not available (context-budget needs jq)"
        return 0
    fi
    local sb dir
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    dir="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")"
    # A second, NEWER session file standing in for the post-handoff session.
    #
    # THE NAME IS LOad-BEARING. plant_transcript writes `session.jsonl`, so this
    # file must sort AFTER it alphabetically for the test to mean anything: glob
    # order and mtime order have to DISAGREE, otherwise a "take the first file"
    # regression picks the same file the correct mtime comparison does and the
    # case passes with and without the fix. (Named `newer.jsonl` it sorts BEFORE
    # `session.jsonl` and this test is a tautology — caught by a mutation round,
    # which is the only thing that can find it.)
    command printf '%s\n' "$TRANSCRIPT_CTX_OK" >"$dir/zz-newest.jsonl"
    # Push the OLD file's mtime into the past rather than touching the new one to
    # "now". Both files are created within the same second, and `-nt` compares
    # whole seconds on many filesystems — so a bare `touch` of the newer file
    # leaves the two mtimes EQUAL, `-nt` is false, and the test fails
    # intermittently depending on where the second boundary lands. Backdating the
    # older file makes the ordering unambiguous and the case deterministic.
    command touch -t 202001010000 "$dir/session.jsonl"
    run_ctx_budget "$sb" "$sb/.worktrees/issue-42"
    assert_contains "$RUN_OUT" "context_tokens=20000" "reads the newest session, not the first"
    assert_contains "$RUN_OUT" "verdict=ok" "a post-handoff session reads back at the floor"
}

run_test test_reads_last_toplevel_record_not_a_sum "reads the last top-level record, not a sum"
run_test test_a_smaller_last_record_wins "a smaller last record wins over a larger earlier one"
run_test test_excludes_sidechain_records "excludes sub-workflow records"
run_test test_ignores_a_trailing_usageless_record "reads past a trailing usage-less record"
run_test test_skips_a_malformed_trailing_line "skips a malformed trailing line"
run_test test_verdict_handoff_at_exactly_the_threshold "handoff at exactly the threshold"
run_test test_verdict_advise_one_below_the_threshold "advise one token below the threshold"
run_test test_verdict_advise_at_exactly_eighty_percent "advise at exactly 80% of threshold"
run_test test_verdict_ok_just_below_the_advisory_band "ok just below the advisory band"
run_test test_missing_transcript_dir_fails_loud "missing transcript dir fails loud (exit 2)"
run_test test_no_toplevel_record_fails_loud "no top-level record fails loud (exit 2)"
run_test test_no_subcommand_exits_1 "no subcommand is a usage error"
run_test test_unknown_subcommand_exits_1 "unknown subcommand is a usage error"
run_test test_non_numeric_threshold_fails_loud "non-numeric threshold fails loud"
run_test test_leading_zero_octal_threshold_fails_loud "leading-zero threshold fails loud (octal/decimal split)"
run_test test_invalid_octal_threshold_fails_loud_not_crash "invalid-octal threshold fails loud, does not crash"
run_test test_leading_zero_floor_fails_loud "leading-zero floor fails loud too (sibling knob)"
run_test test_zero_threshold_fails_loud "zero threshold fails loud"
run_test test_threshold_and_floor_are_env_overridable "threshold + floor are env-overridable"
run_test test_emits_the_documented_default_threshold_and_floor "emits the documented defaults"
run_test test_missing_jq_exits_3 "an absent jq exits 3 (absence forced, not observed)"
run_test test_config_export_propagates_to_the_subprocess "config.sh export propagates to the subprocess"
run_test test_defaults_match_config_sh "defaults match config.sh (drift guard)"
run_test test_reads_the_newest_session_transcript "reads the newest session transcript"

generate_report
