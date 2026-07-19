#!/usr/bin/env bash
# next-issue -> ship-issue state-file hand-off ordering gate (issue #409).
#
# The pipeline hands off through the state file
# `.claude/memory/tmp/next-issue-{N}.json`: `/next-issue` writes it (Phase 1/2)
# and `/ship-issue` reads it (Step 1). That write is a mutation, and plan mode
# permits ONLY edits to the plan file. If the skill prose orders `EnterPlanMode`
# before the state write, the write is silently blocked and never lands — the
# whole L1 interactive path breaks with a false "nothing to ship" (issue #409).
#
# This gate pins the fix as a prose-ordering contract so it cannot silently
# regress:
#
#   1. next-issue/SKILL.md Phase 0 does NOT instruct an immediate `EnterPlanMode`
#      (the trap is removed) and DOES document that the state write precedes plan
#      mode.
#   2. next-issue/phase2-plan.md orders the "Update state file" step BEFORE the
#      first `EnterPlanMode` mention (structural line-order check).
#   3. ship-issue/SKILL.md Step 1 documents the missing-state reconstruction
#      fallback (branch parse + `status/in-progress` + reconstruct) instead of
#      only dead-ending.
#
# Pure bash + coreutils; no node/jq. Skill files are located by `find` so the
# gate is layout-independent (mirrors validate-contracts.sh). Files absent =>
# the suite skips rather than false-passing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "next-issue -> ship-issue hand-off ordering (#409)"

# --- Locators (layout-independent, first match wins) ------------------------

find_next_issue_skill() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/next-issue/SKILL.md' \
        2>/dev/null | command sort | command head -1
}

find_phase2_plan() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/next-issue/phase2-plan.md' \
        2>/dev/null | command sort | command head -1
}

find_ship_skill() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/SKILL.md' \
        2>/dev/null | command sort | command head -1
}

# First 1-indexed line number in <file> matching the extended regex <re>, or
# empty if none. Deterministic (first hit) — used for line-order assertions.
first_line_matching() {
    local file="$1" re="$2"
    command grep -nE -- "$re" "$file" 2>/dev/null | command head -1 | command cut -d: -f1
}

# --- 1. next-issue/SKILL.md: Phase 0 does not trap; write precedes plan mode -

# The Phase 0 "Enter plan mode" step used to say, on the L1 path, to call
# EnterPlanMode "here immediately" / "at the start". The fix defers the call to
# Phase 2 for every disposition. Assert that immediate-at-Phase-0 wording is gone
# from the Phase 0 step, and that the skill states the state write happens before
# plan mode.
test_skill_phase0_defers_plan_mode() {
    local skill
    skill="$(find_next_issue_skill)"
    if [ -z "$skill" ]; then
        skip_test "no next-issue/SKILL.md found"
        return
    fi

    # Slice the Phase 0 section (from its header to the Phase 1 header) and
    # assert the trap wording ("immediately at the start" / "call it here
    # immediately") is absent from it.
    local phase0
    phase0="$(command awk '/^## Phase 0/{f=1} /^## Phase 1/{f=0} f' "$skill")"
    assert_not_contains "$phase0" "call it here immediately" \
        "Phase 0 must not instruct an immediate EnterPlanMode on the L1 path (#409)"

    # Positive: the skill documents that the state write / Phase 1 mutations
    # happen before plan mode.
    assert_true "command grep -qiE 'before .*(EnterPlanMode|Phase 2 .*plan mode|plan mode)' '$skill'" \
        "SKILL.md must document that the state write precedes plan mode (#409)"

    # Positive: the Phase 0 step explicitly says NOT to enter plan mode there.
    assert_true "printf '%s' \"\$phase0\" | command grep -qiE 'Do NOT enter plan mode (here|at the start)'" \
        "Phase 0 step must explicitly defer plan mode to Phase 2 (#409)"
}

# --- 2. phase2-plan.md: state write ordered before EnterPlanMode -------------

test_phase2_write_precedes_plan_mode() {
    local f
    f="$(find_phase2_plan)"
    if [ -z "$f" ]; then
        skip_test "no next-issue/phase2-plan.md found"
        return
    fi

    # Anchor on the imperative EnterPlanMode *invocation* step ("Call
    # **`EnterPlanMode`** now"), not the descriptive intro/summary mentions that
    # legitimately precede the write step.
    local write_line plan_line
    write_line="$(first_line_matching "$f" 'Update state file')"
    plan_line="$(first_line_matching "$f" 'Call \*\*.EnterPlanMode')"

    assert_not_empty "$write_line" "phase2-plan.md must have an 'Update state file' step"
    assert_not_empty "$plan_line" "phase2-plan.md must have a 'Call EnterPlanMode' invocation step"

    if [ -n "$write_line" ] && [ -n "$plan_line" ]; then
        # Line-order: the state write step must appear before the first
        # EnterPlanMode. Numeric compare (10#-normalized against stray zeros).
        if [ "$((10#$write_line))" -lt "$((10#$plan_line))" ]; then
            return 0
        fi
        _fail "state-write step must precede EnterPlanMode in phase2-plan.md (#409)" \
            "Update state file: line $write_line" \
            "EnterPlanMode:      line $plan_line"
    fi
}

# --- 3. ship-issue/SKILL.md: Step 1 reconstruction fallback ------------------

test_ship_documents_reconstruction() {
    local skill
    skill="$(find_ship_skill)"
    if [ -z "$skill" ]; then
        skip_test "no ship-issue/SKILL.md found"
        return
    fi

    # The fallback must: mention reconstruction, parse the issue from the branch,
    # and gate on status/in-progress. Each is a distinct guarantee.
    assert_true "command grep -qi 'reconstruct' '$skill'" \
        "ship Step 1 must document state reconstruction when the file is absent (#409)"
    assert_true "command grep -qE 'issue-\\[0-9\\]\\+|from the branch|branch .*issue' '$skill'" \
        "ship reconstruction must parse the issue number from the branch (#409)"
    assert_true "command grep -q 'status/in-progress' '$skill'" \
        "ship reconstruction must confirm the issue is status/in-progress (#409)"
}

# --- Positive controls: the target files exist ------------------------------

test_target_files_present() {
    local missing=""
    [ -n "$(find_next_issue_skill)" ] || missing="${missing} next-issue/SKILL.md"
    [ -n "$(find_phase2_plan)" ] || missing="${missing} next-issue/phase2-plan.md"
    [ -n "$(find_ship_skill)" ] || missing="${missing} ship-issue/SKILL.md"
    if [ -n "$missing" ]; then
        skip_test "target skill files absent:${missing}"
        return
    fi
    assert_true "true" "All three hand-off skill files are present"
}

run_test test_target_files_present "Hand-off skill files present (positive control)"
run_test test_skill_phase0_defers_plan_mode "next-issue Phase 0 defers plan mode; write precedes it (#409)"
run_test test_phase2_write_precedes_plan_mode "phase2-plan.md orders state write before EnterPlanMode (#409)"
run_test test_ship_documents_reconstruction "ship-issue Step 1 documents reconstruction fallback (#409)"

generate_report
