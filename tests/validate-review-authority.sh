#!/usr/bin/env bash
# Review-harness authority + loud-skip contract gate (issue #637).
#
# Two rules collide during a golem's `/workflow:ship-issue` run: the harness
# system prompt restricts the `Workflow` tool to explicit opt-in, while this
# skill *mandates* a Workflow call for the adversarial review. The tool's own
# description resolves it — invoking a slash command whose instructions direct
# the call IS opt-in — but until #637 no skill in this repo cited that clause,
# so every golem re-derived it. Observed consequence: a golem declined the
# harness and substituted a serial in-context review, costing hours of wall time
# for a weaker result, and the completion summary had no vocabulary to say the
# review had not run (the only non-blocking value was `clean`).
#
# This gate pins the resolution as a prose contract so it cannot silently
# regress:
#
#   1. ship-issue/SKILL.md + ship-protocol.md assert the Workflow opt-in
#      authority (AC1) — the invocation is settled, not re-derived per run.
#   2. Both graceful-degradation clauses (pre-ship-validation.md,
#      ci-review-protocol.md) restrict the skip to MECHANICAL failure and
#      exclude "I lack permission" as a reason (AC2).
#   3. Both clauses forbid substituting a hand-rolled review (AC2, widened from
#      the observed failure).
#   4. execute-protocol.md's `Review status` enum carries `skipped` (AC3).
#   5. A skipped review is bound to the merge invariant — never auto-merge (AC3).
#
# Every assertion here is DOC-SHAPED, which is exactly the shape that writes
# itself tautologically (see the anchored-regex-tautological-test and
# mutate-after-every-security-fixture lessons). Each case below was verified by
# mutating the source line it guards and confirming the case FAILS without the
# fix; the mutation recipe is in the header comment of each section.
#
# Pure bash + coreutils; no node/jq. Skill files are located by `find` so the
# gate is layout-independent (mirrors validate-next-issue-handoff.sh). Files
# absent => the case skips rather than false-passing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Review-harness authority + loud skip (#637)"

# --- Locators (layout-independent, first match wins) ------------------------

find_ship_skill() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/SKILL.md' \
        2>/dev/null | command sort | command head -1
}

find_ship_protocol() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/ship-protocol.md' \
        2>/dev/null | command sort | command head -1
}

find_pre_ship() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/pre-ship-validation.md' \
        2>/dev/null | command sort | command head -1
}

find_ci_review() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/ci-review-protocol.md' \
        2>/dev/null | command sort | command head -1
}

find_execute_protocol() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/ship-issue/execute-protocol.md' \
        2>/dev/null | command sort | command head -1
}

# --- 1. AC1: the Workflow opt-in authority is asserted ----------------------
#
# Mutation check: delete the "Workflow authority" heading from ship-protocol.md,
# or the "already opted in" sentence from SKILL.md -> this case fails.

test_workflow_authority_asserted() {
    local skill protocol
    skill="$(find_ship_skill)"
    protocol="$(find_ship_protocol)"
    if [ -z "$skill" ] || [ -z "$protocol" ]; then
        skip_test "ship-issue SKILL.md / ship-protocol.md not found"
        return
    fi

    # The deep authority section exists and names the opt-in clause it relies on.
    assert_true "command grep -qi 'Workflow authority' '$protocol'" \
        "ship-protocol.md must carry a 'Workflow authority' section (#637 AC1)"
    assert_true "command grep -qiE 'slash command whose instructions' '$protocol'" \
        "authority must cite the tool's slash-command opt-in clause (#637 AC1)"

    # The skill itself states it, so a golem reading SKILL.md alone is settled.
    assert_true "command grep -qiE 'opted in|opt-in' '$skill'" \
        "ship-issue/SKILL.md must state the harness call is already opted in (#637 AC1)"
    assert_true "command grep -qi 'Workflow authority' '$skill'" \
        "ship-issue/SKILL.md must point at the Workflow authority rule (#637 AC1)"
}

# --- 1a. AC1: the substitute's measured cost is stated ----------------------
#
# Prose alone ("slower and weaker") is easy to discount; the measurement is not.
# A consuming repo never loads librarian's CLAUDE.md, so the numbers recorded
# there by #645 have to live in the skill too or they do not travel with the
# plugin.
#
# Mutation check: delete the measurement table from ship-protocol.md -> fails.

test_substitute_cost_is_measured() {
    local protocol
    protocol="$(find_ship_protocol)"
    if [ -z "$protocol" ]; then
        skip_test "ship-protocol.md not found"
        return
    fi

    # The concrete figures, not just an assertion that substitutes are bad.
    assert_true "command grep -qiE '5\.4 min' '$protocol'" \
        "ship-protocol.md must state the measured harness cycle time (#637/#645)"
    assert_true "command grep -qiE '2\.5 ?h' '$protocol'" \
        "ship-protocol.md must state the measured serial-substitute total (#637/#645)"
    # The qualitative losses are what make the substitute worse, not just slower.
    assert_true "command grep -qiE 'pre-scan handoff' '$protocol'" \
        "ship-protocol.md must name what the substitute loses (#637/#645)"
}

# --- 1b. AC1: the INVOCATION SITES cite the authority ----------------------
#
# The observed failure happened at a call site: a golem read an "Invoke the
# `Workflow` tool" step in isolation and re-derived the permission question
# there. A standalone authority section in ship-protocol.md does not help a
# reader who never navigates to it, so the inline citation next to each
# invocation is the load-bearing part of AC1 — assert it directly rather than
# trusting that the summary docs imply it.
#
# Mutation check: delete the "already opted in" citation from either
# invocation site -> this case fails for that file.

test_invocation_sites_cite_authority() {
    local pre ci f
    pre="$(find_pre_ship)"
    ci="$(find_ci_review)"
    if [ -z "$pre" ] || [ -z "$ci" ]; then
        skip_test "pre-ship-validation.md / ci-review-protocol.md not found"
        return
    fi

    # PER-SITE, not per-file. ci-review-protocol.md has TWO invocation sites
    # (the ci-fixer call and the pr-cycle re-review); a whole-file grep cannot
    # tell "both cite the authority" from "one regressed and the other still
    # does". Count the sites, then require a citation within the window
    # following each one — a golem reads a single invocation step in isolation,
    # which is the whole reason #637 exists.
    # Match only BOLD invocation steps (`**Invoke the \`Workflow\` tool**`) —
    # that is the imperative "make this call here" form. A plain-text mention
    # like "Invoke the `Workflow` tool as a **background** task" is a
    # back-reference to a call already introduced above, and demanding a
    # citation there would require a redundant one.
    local sites cited
    for f in "$pre" "$ci"; do
        sites="$(command grep -cE '\*\*Invoke the .?`?Workflow`?.? tool\*\*' "$f")"
        assert_true "[ \"$sites\" -ge 1 ]" \
            "$(basename "$f"): expected a Workflow invocation step (positive control, #637 AC1)"

        # Count sites whose following 4-line window carries "already opted in".
        cited="$(command awk '
            /\*\*Invoke the .?`?Workflow`?.? tool\*\*/ { win = 4 }
            win > 0 && /already opted in/ { hit++; win = 0; next }
            win > 0 { win-- }
            END { print hit + 0 }
        ' "$f")"
        assert_equals "$sites" "$cited" \
            "$(basename "$f"): EVERY Workflow invocation site must say the call is already opted in (#637 AC1)"

        assert_true "command grep -qi 'Workflow authority' '$f'" \
            "$(basename "$f"): must cite ship-protocol.md § Workflow authority (#637 AC1)"
    done
}

# --- 2. AC2: "unavailable" is narrowed to mechanical failure ----------------
#
# Mutation check: delete the permission-exclusion sentence from either clause
# -> this case fails for that file.

test_degradation_excludes_permission_doubt() {
    local pre ci f
    pre="$(find_pre_ship)"
    ci="$(find_ci_review)"
    if [ -z "$pre" ] || [ -z "$ci" ]; then
        skip_test "pre-ship-validation.md / ci-review-protocol.md not found"
        return
    fi

    # Both clauses must scope the skip to mechanical failure AND name the
    # excluded reason. Checking both halves separately: a file could plausibly
    # say "mechanical" while omitting the permission carve-out that is the
    # actual fix.
    #
    # The "mechanical" check is SLICED to the degradation heading itself.
    # pre-ship-validation.md says "mechanical" three times — two of them
    # ("mechanical issues" line 65, "mechanical findings" line 131) predate this
    # change and have nothing to do with the skip scoping, so a whole-file grep
    # passes even with the scoping phrase deleted. Anchoring on the heading is
    # what makes the assertion mean what it claims.
    for f in "$pre" "$ci"; do
        assert_true "command grep -qiE '^[[:space:]]*\*\*Graceful degradation — mechanical failure only' '$f'" \
            "$(basename "$f"): the degradation heading itself must scope the skip to mechanical failure (#637 AC2)"
        assert_true "command grep -qiE 'permission' '$f'" \
            "$(basename "$f"): degradation must address the permission-doubt case (#637 AC2)"
        assert_true "command grep -qiE '(lack|lacking) permission|permission doubt is not' '$f'" \
            "$(basename "$f"): must exclude 'I lack permission' as a skip reason (#637 AC2)"
    done
}

# --- 3. AC2 (widened): no hand-rolled substitute review ---------------------
#
# The observed failure was not a clean skip — the golem re-implemented the
# review serially in-context, which reports as a review having run.
#
# Mutation check: delete the "Never substitute" sentence from either clause
# -> this case fails for that file.

test_degradation_forbids_substitute_review() {
    local pre ci f
    pre="$(find_pre_ship)"
    ci="$(find_ci_review)"
    if [ -z "$pre" ] || [ -z "$ci" ]; then
        skip_test "pre-ship-validation.md / ci-review-protocol.md not found"
        return
    fi

    for f in "$pre" "$ci"; do
        assert_true "command grep -qiE 'never substitute|do \*\*not\*\* re-implement|not re-implement' '$f'" \
            "$(basename "$f"): must forbid substituting a hand-rolled review (#637 AC2)"
    done
}

# --- 4. AC3: the Review status enum carries `skipped` -----------------------
#
# Mutation check: drop `| skipped: {reason}` from the enum line -> this fails.

test_review_status_enum_has_skipped() {
    local f enum_line
    f="$(find_execute_protocol)"
    if [ -z "$f" ]; then
        skip_test "execute-protocol.md not found"
        return
    fi

    # Anchor on the enum line itself, not on the word "skipped" anywhere in the
    # file — a passing match elsewhere would make this tautological.
    enum_line="$(command grep -E '\*\*Review status\*\*:' "$f" 2>/dev/null | command head -1)"
    assert_not_empty "$enum_line" \
        "execute-protocol.md must render a **Review status** line (#637 AC3)"
    assert_contains "$enum_line" "skipped" \
        "the Review status enum must include a 'skipped' value (#637 AC3)"
    # The pre-existing values must survive the addition.
    assert_contains "$enum_line" "clean" \
        "the Review status enum must retain 'clean' (#637 AC3)"
    assert_contains "$enum_line" "stopped-with-blocking" \
        "the Review status enum must retain 'stopped-with-blocking' (#637 AC3)"
}

# --- 5. AC3: a skipped review gates like a failure --------------------------
#
# The enum value alone is cosmetic — it matters only if a skip blocks the
# auto-merge. Assert the binding, not just the vocabulary.
#
# Mutation check: delete the "A skipped review is not a clean review" paragraph
# -> this case fails.

test_skipped_review_blocks_auto_merge() {
    local f para
    f="$(find_execute_protocol)"
    if [ -z "$f" ]; then
        skip_test "execute-protocol.md not found"
        return
    fi

    # Slice the skip paragraph. `status/pr-pending` appears SEVEN times in this
    # file (the L3-L4 and L1-L2 labeling steps, unrelated to the skip case), so
    # a whole-file grep for it passes even if the skip clause drops its park
    # instruction entirely. Same scoping the Option 2 and cap-exhaustion cases
    # already use; this case was left unscoped until cycle 5 caught it.
    para="$(command awk '
        done_slice { next }
        /A skipped review is not a clean review/ { inpara = 1 }
        inpara && /^[[:space:]]*$/ { done_slice = 1; next }
        inpara { print }
    ' "$f")"

    assert_not_empty "$para" \
        "execute-protocol.md must carry the skipped-is-not-clean paragraph (#637 AC3)"
    assert_true "printf '%s' \"\$para\" | command grep -qiE 'stopped-with-blocking'" \
        "the skip clause must equate a skip with stopped-with-blocking (#637 AC3)"
    assert_true "printf '%s' \"\$para\" | command grep -qiE 'never auto-merge|do \*\*NOT\*\* merge'" \
        "the skip clause must carry the never-auto-merge rule (#637 AC3)"
    assert_true "printf '%s' \"\$para\" | command grep -q 'status/pr-pending'" \
        "the skip clause itself must park the PR with status/pr-pending (#637 AC3)"

    # The merge invariant must also name the skip as a dead-end trigger; that
    # sentence lives outside the paragraph above, so check it file-level.
    assert_true "command grep -qiE 'skipped rather than run' '$f'" \
        "the merge invariant must list a skipped review as a dead-end (#637 AC3)"
}

# --- 5b. AC3: the skip gate covers Option 2's push, not just Option 1 -------
#
# Found by the cycle-3 review: the merge invariant was wired only into Option
# 1's gate, but the review "Runs on Options 1, 2, and 3 alike". Option 2 pushes
# straight to `main` with no PR to park, so an ungated skip there is strictly
# worse than on Option 1 — the only remedy is a revert.
#
# Mutation check: delete the Option 2 review-gate block from execute-protocol.md
# -> this case fails.

test_option2_gates_on_review_status() {
    local f opt2
    f="$(find_execute_protocol)"
    if [ -z "$f" ]; then
        skip_test "execute-protocol.md not found"
        return
    fi

    # Slice Option 2's section so a match inside Option 1's gate cannot satisfy
    # this — the whole point is that Option 1's wiring did NOT cover Option 2.
    opt2="$(command awk '/^## Option 2/{f=1} /^## Option 3/{f=0} f' "$f")"
    assert_not_empty "$opt2" \
        "execute-protocol.md must have an Option 2 section (positive control, #637 AC3)"
    assert_true "printf '%s' \"\$opt2\" | command grep -qiE 'skipped'" \
        "Option 2 must address a skipped review before pushing (#637 AC3)"
    # BOTH halves of the disjunction, not just the skip. Narrowing the gate to
    # react only to a mechanically-skipped review would let a run with live
    # blocking findings push to `main` — the same class of gap, reopened.
    assert_true "printf '%s' \"\$opt2\" | command grep -qiE 'stopped-with-blocking'" \
        "Option 2 must also gate on stopped-with-blocking, not just skipped (#637 AC3)"
    assert_true "printf '%s' \"\$opt2\" | command grep -qiE 'do NOT .?git push|not .?git push'" \
        "Option 2 must forbid the push when the review did not run clean (#637 AC3)"
    assert_true "printf '%s' \"\$opt2\" | command grep -qiE 'Option 3'" \
        "Option 2 must name the commit-only fallback (#637 AC3)"
}

# --- 5c. AC3: the cap-exhaustion path also respects the Option 2 gate -------
#
# Found by the cycle-4 review: the autonomous cap-exceeded bullet said to
# "push for Option 2" when the cycle cap ran out with blocking findings still
# unresolved — which IS `stopped-with-blocking`, the exact state the Option 2
# gate forbids pushing on. Closing the harness-skip path while leaving the
# cap-exhaustion path open reopens the gap by another route.
#
# Mutation check: restore the bare "push for Option 2" wording -> this fails.

test_cap_exhaustion_respects_option2_gate() {
    local f para
    f="$(find_pre_ship)"
    if [ -z "$f" ]; then
        skip_test "pre-ship-validation.md not found"
        return
    fi

    # Slice the FIRST Autonomous bullet and stop at the first blank-line-led
    # paragraph break, so a match elsewhere in the file cannot satisfy this —
    # the bullet itself has to carry the deferral. `done` latches so the slice
    # can never re-arm on a later match and silently union two paragraphs (which
    # is how this very assertion first passed a mutation it should have failed).
    para="$(command awk '
        done_slice { next }
        /\*\*Autonomous\*\*: do NOT prompt/ { inpara = 1 }
        inpara && /^[[:space:]]*$/ { done_slice = 1; next }
        inpara { print }
    ' "$f")"
    assert_not_empty "$para" \
        "pre-ship-validation.md must have an Autonomous cap-exceeded bullet (positive control, #637)"
    assert_true "printf '%s' \"\$para\" | command grep -qiE 'Option 2 review gate|apply the .*review gate'" \
        "the cap-exceeded bullet must defer to the Option 2 review gate (#637 AC3)"
    assert_true "printf '%s' \"\$para\" | command grep -qiE 'stopped-with-blocking'" \
        "the cap-exceeded bullet must name the state it produces (#637 AC3)"
}

# --- Positive control: the target files exist -------------------------------

test_target_files_present() {
    local missing=""
    [ -n "$(find_ship_skill)" ] || missing="${missing} ship-issue/SKILL.md"
    [ -n "$(find_ship_protocol)" ] || missing="${missing} ship-issue/ship-protocol.md"
    [ -n "$(find_pre_ship)" ] || missing="${missing} ship-issue/pre-ship-validation.md"
    [ -n "$(find_ci_review)" ] || missing="${missing} ship-issue/ci-review-protocol.md"
    [ -n "$(find_execute_protocol)" ] || missing="${missing} ship-issue/execute-protocol.md"
    if [ -n "$missing" ]; then
        skip_test "target skill files absent:${missing}"
        return
    fi
    assert_true "true" "All five ship-issue contract files are present"
}

run_test test_target_files_present "ship-issue contract files present (positive control)"
run_test test_workflow_authority_asserted "Workflow opt-in authority is asserted once (#637 AC1)"
run_test test_substitute_cost_is_measured "Substitute review's measured cost is stated (#637 AC1/#645)"
run_test test_invocation_sites_cite_authority "Workflow invocation sites cite the authority (#637 AC1)"
run_test test_degradation_excludes_permission_doubt "Degradation clauses exclude permission doubt (#637 AC2)"
run_test test_degradation_forbids_substitute_review "Degradation clauses forbid a substitute review (#637 AC2)"
run_test test_review_status_enum_has_skipped "Review status enum carries 'skipped' (#637 AC3)"
run_test test_skipped_review_blocks_auto_merge "A skipped review blocks auto-merge (#637 AC3)"
run_test test_option2_gates_on_review_status "Option 2 gates its push on review status (#637 AC3)"
run_test test_cap_exhaustion_respects_option2_gate "Cap exhaustion respects the Option 2 gate (#637 AC3)"

generate_report
