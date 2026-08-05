#!/usr/bin/env bash
# status/pr-pending label lifecycle gate (issue #654).
#
# `status/pr-pending` is the label that keeps a shipped-but-unmerged issue out
# of `/workflow:next-issue`'s priority queries. It was ADDED on every Option 1
# delivery path and never removed, so the squash commit's `Closes #N` closed the
# issue with a stale in-flight label riding along — polluting the `status/*`
# filters the label exists to serve.
#
# The fix has two halves, and this gate pins BOTH as prose contracts:
#
#   1. ADD-SIDE (AC1) — the L3-L4 auto-merge cleanup step must NOT add the
#      label (the merge already landed; the wait is over) and must REMOVE it.
#      The L1-L2 path must still ADD it — there the PR is genuinely open. That
#      second assertion is what stops an over-broad "delete every add" fix.
#   2. REMOVE-SIDE (AC2) — `/workflow:golem --teardown N` owns the out-of-band
#      sweep, in its verified-MERGED branch only. An unmerged PR keeps the
#      label.
#
# Plus AC3: all three park sites (L2 completion summary, CI dead-end, canonical
# dead-end rule) must tell the human the label comes off once the PR lands, and
# AC4: the idempotency semantics must be documented where the sweep lives.
#
# Every site that changes a GitHub `--remove-label` must change its GitLab
# `--unlabel` sibling too (the harden-one-knob-grep-every-sibling class).
#
# Pure bash + coreutils; no node/jq. Skill files are located by `find` so the
# gate is layout-independent (mirrors validate-next-issue-handoff.sh). Files
# absent => the suite skips rather than false-passing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "status/pr-pending label lifecycle (#654)"

# --- Locators (layout-independent, first match wins) ------------------------

find_execute_protocol() {
    command find "$PLUGINS_DIR" -type f \
        -path '*/skills/ship-issue/execute-protocol.md' \
        2>/dev/null | command sort | command head -1
}

find_ci_review_protocol() {
    command find "$PLUGINS_DIR" -type f \
        -path '*/skills/ship-issue/ci-review-protocol.md' \
        2>/dev/null | command sort | command head -1
}

find_golem_skill() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/golem/SKILL.md' \
        2>/dev/null | command sort | command head -1
}

find_autonomy_levels() {
    command find "$PLUGINS_DIR" -type f \
        -path '*/skills/orchestrate/autonomy-levels.md' \
        2>/dev/null | command sort | command head -1
}

# --- 1. AC1 add-side: the L3-L4 merge cleanup removes, never adds ------------

# The L3-L4 cleanup step (a) runs AFTER the merge has landed. Slice it from its
# "a." marker to the following "b." marker so the assertions cannot accidentally
# read the L1-L2 step further down the file.
test_merge_cleanup_removes_not_adds() {
    local f
    f="$(find_execute_protocol)"
    if [ -z "$f" ]; then
        skip_test "no ship-issue/execute-protocol.md found"
        return
    fi

    local step_a
    step_a="$(command awk '/^     a\./{f=1} /^     b\./{f=0} f' "$f")"

    if [ -z "$step_a" ]; then
        skip_test "could not slice the L3-L4 cleanup step (a) from execute-protocol.md"
        return
    fi

    # The defect itself: adding a label the merge just made meaningless.
    assert_not_contains "$step_a" '--add-label "status/pr-pending"' \
        "L3-L4 post-merge cleanup must NOT add status/pr-pending (#654 AC1)"

    # The fix: it removes it instead, on both platforms.
    assert_true "printf '%s' \"\$step_a\" | command grep -q -- '--remove-label \"status/pr-pending\"'" \
        "L3-L4 post-merge cleanup must remove status/pr-pending (#654 AC1)"
    assert_true "printf '%s' \"\$step_a\" | command grep -q -- '--unlabel \"status/pr-pending\"'" \
        "L3-L4 cleanup must carry the GitLab --unlabel sibling (#654 AC1)"

    # status/in-progress removal is pre-existing behavior that must survive.
    assert_true "printf '%s' \"\$step_a\" | command grep -q -- '--remove-label \"status/in-progress\"'" \
        "L3-L4 cleanup must still remove status/in-progress (#654 AC1)"
}

# --- 2. AC1 guard: the L1-L2 path still ADDS the label -----------------------

# Counterweight to test 1. An over-broad fix that strips every `--add-label
# status/pr-pending` would break the label's entire purpose: on L1-L2 the PR IS
# open and awaiting a human merge, which is exactly what the label signals.
test_l1_l2_still_adds_label() {
    local f
    f="$(find_execute_protocol)"
    if [ -z "$f" ]; then
        skip_test "no ship-issue/execute-protocol.md found"
        return
    fi

    assert_true "command grep -q -- '--add-label \"status/pr-pending\"' '$f'" \
        "the L1-L2 ship path must still ADD status/pr-pending (#654 AC1 guard)"
    assert_true "command grep -q -- '--label \"status/pr-pending\"' '$f'" \
        "the L1-L2 GitLab sibling must still add status/pr-pending (#654 AC1 guard)"
}

# --- 3. AC2: golem --teardown owns the sweep, merged-branch only -------------

test_teardown_owns_the_sweep() {
    local f
    f="$(find_golem_skill)"
    if [ -z "$f" ]; then
        skip_test "no golem/SKILL.md found"
        return
    fi

    # Slice the --teardown re-entry bullet: from its marker to the "## When to
    # Use" section that follows Phase D. The sweep must live INSIDE this block,
    # which is the region already gated on `state == MERGED`.
    local teardown
    teardown="$(command awk '/`--teardown N` re-entry/{f=1} /^## When to Use/{f=0} f' "$f")"

    if [ -z "$teardown" ]; then
        skip_test "could not slice the --teardown re-entry block from golem/SKILL.md"
        return
    fi

    # Both commands must use the braced `{N}` placeholder, matching every other
    # issue-number token in this file and its companion docs. A bare `N` reads
    # like a literal an agent could paste into a shell verbatim, so pin the
    # spelling rather than just the presence of the command.
    assert_true "printf '%s' \"\$teardown\" | command grep -q 'gh issue edit {N} --remove-label \"status/pr-pending\"'" \
        "--teardown must remove status/pr-pending, using the {N} placeholder (#654 AC2)"
    assert_true "printf '%s' \"\$teardown\" | command grep -q 'glab issue update {N} --unlabel \"status/pr-pending\"'" \
        "--teardown must carry the GitLab --unlabel sibling, using {N} (#654 AC2)"

    # Merged-only: the block must say the unmerged branch keeps the label, so a
    # reader cannot hoist the sweep above the MERGED check.
    assert_true "printf '%s' \"\$teardown\" | command grep -qiE 'merged.only|only on the verified.MERGED|must .*keep. the label'" \
        "--teardown must scope the sweep to the verified-MERGED branch (#654 AC2)"

    # AC4: the idempotency semantics are documented at the sweep site.
    assert_true "printf '%s' \"\$teardown\" | command grep -qi 'idempotent'" \
        "the sweep site must document idempotency (#654 AC4)"
    assert_true "printf '%s' \"\$teardown\" | command grep -qiE 'no-op|exits 0'" \
        "the sweep site must state that removing an absent label is a clean no-op (#654 AC4)"
}

# --- 4. AC3: every park site states the removal obligation -------------------

# Three distinct sites park a PR with the label. Each must tell the human it
# comes off once the PR lands, because in every one of them the merge happens
# after the run has exited.
test_park_sites_state_the_obligation() {
    local f_exec f_ci f_auto
    f_exec="$(find_execute_protocol)"
    f_ci="$(find_ci_review_protocol)"
    f_auto="$(find_autonomy_levels)"

    local missing=""
    [ -n "$f_exec" ] || missing="${missing} ship-issue/execute-protocol.md"
    [ -n "$f_ci" ] || missing="${missing} ship-issue/ci-review-protocol.md"
    [ -n "$f_auto" ] || missing="${missing} orchestrate/autonomy-levels.md"
    if [ -n "$missing" ]; then
        skip_test "park-site files absent:${missing}"
        return
    fi

    # Site 1 — the L2 completion summary. Slice from its header to the "Then
    # STOP" line that closes the block, then assert on the matched text directly
    # (a real expansion, so shellcheck can see the slice is used).
    local summary summary_hit
    summary="$(command awk '/^   ## Ship summary/{f=1} /Then STOP/{f=0} f' "$f_exec")"
    summary_hit="$(printf '%s' "$summary" |
        command grep -iE 'remove .status/pr-pending|After you merge' || true)"
    assert_not_empty "$summary_hit" \
        "the L2 completion summary must state the post-merge label removal (#654 AC3)"

    # Site 2 — the CI dead-end park.
    assert_true "command grep -qiE 'must come .*off|remove .*status/pr-pending' '$f_ci'" \
        "the CI dead-end park must state the post-merge label removal (#654 AC3)"

    # Site 3 — the canonical dead-end rule.
    assert_true "command grep -qiE 'removed once the PR lands|remove .*status/pr-pending' '$f_auto'" \
        "the canonical dead-end rule must state the post-merge label removal (#654 AC3)"
}

# --- 5. Sibling parity: no GitHub-only label mutation ------------------------

# Every file this fix touches that gained a GitHub `--remove-label
# status/pr-pending` must also carry the GitLab `--unlabel status/pr-pending`.
# A GitHub-only edit is the recurring harden-one-knob-grep-every-sibling defect.
test_gitlab_sibling_parity() {
    local f gh_hits glab_hits
    local checked=0

    for f in "$(find_execute_protocol)" "$(find_golem_skill)" \
        "$(find_ci_review_protocol)" "$(find_autonomy_levels)"; do
        [ -n "$f" ] || continue
        checked=$((checked + 1))

        gh_hits="$(command grep -c -- 'remove-label "status/pr-pending"' "$f" || true)"
        glab_hits="$(command grep -c -- 'unlabel "status/pr-pending"' "$f" || true)"

        # Symmetric on purpose: a GitLab-only mutation is the same defect class
        # as a GitHub-only one, just mirrored. Checking a single direction would
        # let `--unlabel` land without its `--remove-label` sibling silently.
        if [ "$gh_hits" -gt 0 ] && [ "$glab_hits" -eq 0 ]; then
            _fail "GitHub --remove-label without its GitLab --unlabel sibling (#654)" \
                "File: $f" \
                "remove-label hits: $gh_hits, unlabel hits: $glab_hits"
        fi
        if [ "$glab_hits" -gt 0 ] && [ "$gh_hits" -eq 0 ]; then
            _fail "GitLab --unlabel without its GitHub --remove-label sibling (#654)" \
                "File: $f" \
                "unlabel hits: $glab_hits, remove-label hits: $gh_hits"
        fi
    done

    if [ "$checked" -eq 0 ]; then
        skip_test "no target files found for sibling-parity check"
        return
    fi

    assert_true "true" "GitHub/GitLab label-mutation siblings are paired ($checked files)"
}

# --- Positive controls: the target files exist ------------------------------

test_target_files_present() {
    local missing=""
    [ -n "$(find_execute_protocol)" ] || missing="${missing} ship-issue/execute-protocol.md"
    [ -n "$(find_ci_review_protocol)" ] || missing="${missing} ship-issue/ci-review-protocol.md"
    [ -n "$(find_golem_skill)" ] || missing="${missing} golem/SKILL.md"
    [ -n "$(find_autonomy_levels)" ] || missing="${missing} orchestrate/autonomy-levels.md"
    if [ -n "$missing" ]; then
        skip_test "target skill files absent:${missing}"
        return
    fi
    assert_true "true" "All four label-lifecycle skill files are present"
}

run_test test_target_files_present "Label-lifecycle skill files present (positive control)"
run_test test_merge_cleanup_removes_not_adds "L3-L4 merge cleanup removes, never adds, pr-pending (#654 AC1)"
run_test test_l1_l2_still_adds_label "L1-L2 ship path still adds pr-pending (#654 AC1 guard)"
run_test test_teardown_owns_the_sweep "golem --teardown owns the merged-only sweep (#654 AC2/AC4)"
run_test test_park_sites_state_the_obligation "All three park sites state the removal (#654 AC3)"
run_test test_gitlab_sibling_parity "GitHub/GitLab label-mutation sibling parity (#654)"

generate_report
