# shellcheck shell=bash
# Submodule topology — worktree-scope guard tests (issue #564 split).
#
# Covers a leak into the submodule's real checkout being DENIED, where git-common-dir is <super>/.git/modules/<name> and its parent is git-internal rather than a checkout root (#475).
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

# --- Submodule topology: leak into the submodule's real checkout is DENIED ----
# #501 (was the interim fail-open, #475 pre-PR review finding #1). A submodule
# linked-worktree session (common-dir under <super>/.git/modules/<name>) editing
# the submodule's REAL checkout (<super>/<name>, outside its worktree) must be
# DENIED — the guard now derives main_root from the common-dir's core.worktree
# and enforces instead of failing open.
test_submodule_deny_leak() {
    jq_required || return 0
    if [ "$SM_OK" -ne 1 ]; then
        skip_test "submodule fixture unavailable in this environment"
        return 0
    fi
    run_guard "$SM_WT" "Edit" "file_path" "$SM_SUB/f"
    assert_valid_json "$GUARD_OUT" "submodule deny output is valid JSON"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "submodule->real-checkout leak denied (enforced, not fail-open)"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    assert_contains "$reason" "$SM_SUB" "submodule deny reason names the leaked submodule-checkout path"
    assert_contains "$reason" "$SM_WT" "submodule deny reason names the worktree it should have used"
}
# The submodule worktree's OWN files must still be allowed (the derivation did not
# over-broaden into blocking the worktree itself).
test_submodule_allow_own_worktree() {
    jq_required || return 0
    if [ "$SM_OK" -ne 1 ]; then
        skip_test "submodule fixture unavailable in this environment"
        return 0
    fi
    run_guard "$SM_WT" "Edit" "file_path" "$SM_WT/f"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "submodule worktree's own path allowed"
}
# Poisoning core.bare / core.worktree in the SUBMODULE's own module config (the
# topology that branch actually governs — review finding: the standard-fixture
# poison tests below don't exercise the submodule path) must not disarm the guard:
# the structural `*/.git/modules/*` match ignores both keys, so the leak into the
# submodule's real checkout stays DENIED.
test_submodule_poison_still_denies() {
    jq_required || return 0
    if [ "$SM_OK" -ne 1 ]; then
        skip_test "submodule fixture unavailable in this environment"
        return 0
    fi
    local sm_common
    sm_common="$(git_clean -C "$SM_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$sm_common" ]; then
        skip_test "could not resolve submodule common-dir"
        return 0
    fi
    git_clean -C "$SM_WT" config -f "$sm_common/config" core.bare true 2>/dev/null || true
    git_clean -C "$SM_WT" config -f "$sm_common/config" core.worktree "$FIXTURE" 2>/dev/null || true
    run_guard "$SM_WT" "Edit" "file_path" "$SM_SUB/f"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "submodule core.bare/core.worktree poison does NOT disarm the guard (structural */.git/modules/* wins)"
}
