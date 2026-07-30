# shellcheck shell=bash
# Basic allow/deny decisions — worktree-scope guard tests (issue #564 split).
#
# Covers a worktree session editing a main-checkout path (DENY), the correct worktree path (ALLOW), a main session (never blocked), out-of-repo and relative paths, and `.`/`..` lexical normalization (#475).
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

# --- Deny: worktree session editing a main-checkout path --------------------
test_deny_leak_edit() {
    jq_required || return 0
    run_guard "$WT_DIR" "Edit" "file_path" "$MAIN_DIR/seed.txt"
    assert_valid_json "$GUARD_OUT" "deny output is valid JSON"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "worktree->main leak denied (Edit)"
}
test_deny_leak_write_nested() {
    jq_required || return 0
    run_guard "$WT_DIR" "Write" "file_path" "$MAIN_DIR/plugins/workflow/x.md"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "worktree->main leak denied (nested Write)"
}
test_deny_leak_notebook() {
    jq_required || return 0
    run_guard "$WT_DIR" "NotebookEdit" "notebook_path" "$MAIN_DIR/nb.ipynb"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "worktree->main leak denied (NotebookEdit path field)"
}
test_deny_reason_names_paths() {
    jq_required || return 0
    run_guard "$WT_DIR" "Edit" "file_path" "$MAIN_DIR/seed.txt"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    assert_contains "$reason" "$MAIN_DIR/seed.txt" "deny reason names the leaked path"
    assert_contains "$reason" "$WT_DIR" "deny reason names the worktree it should have used"
    assert_contains "$reason" "checkout --" "deny reason gives the restore-only recovery command"
}

# --- Allow: correct worktree path -------------------------------------------
test_allow_worktree_path() {
    jq_required || return 0
    run_guard "$WT_DIR" "Edit" "file_path" "$WT_DIR/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "edit of the correct worktree path allowed"
    assert_output_empty "$GUARD_OUT" "allow path emits nothing (worktree)"
}
test_allow_worktree_nested_new() {
    jq_required || return 0
    run_guard "$WT_DIR" "Write" "file_path" "$WT_DIR/plugins/new/file.md"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "new file under the worktree allowed"
}

# --- Allow: main session is never blocked -----------------------------------
test_allow_main_session() {
    jq_required || return 0
    run_guard "$MAIN_DIR" "Edit" "file_path" "$MAIN_DIR/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "main-session edit of its own tree allowed"
    assert_output_empty "$GUARD_OUT" "allow path emits nothing (main session)"
}

# --- Allow: out-of-repo + relative ------------------------------------------
test_allow_out_of_repo_tmp() {
    jq_required || return 0
    run_guard "$WT_DIR" "Write" "file_path" "/tmp/scratch-475.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "out-of-repo /tmp target allowed"
}
test_allow_relative_path() {
    jq_required || return 0
    run_guard "$WT_DIR" "Edit" "file_path" "plugins/relative.md"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "relative target allowed (resolves against worktree cwd)"
}
# --- `.`/`..` lexical normalization (#475 pre-PR review finding #2) ----------
# `$WT/../<file>` resolves to a MAIN-checkout path — the natural leak shape, NOT
# an edge to wave through. The guard collapses `.`/`..` lexically before scoping.
test_deny_dotdot_into_main() {
    jq_required || return 0
    # WT_DIR == MAIN_DIR/.worktrees/issue-1, so `../../seed.txt` normalizes up two
    # levels (issue-1 -> .worktrees -> repo) to MAIN_DIR/seed.txt — a real leak.
    run_guard "$WT_DIR" "Edit" "file_path" "$WT_DIR/../../seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "\$WT/../.. into the main checkout is denied (normalized)"
}
test_allow_dot_within_worktree() {
    jq_required || return 0
    run_guard "$WT_DIR" "Edit" "file_path" "$WT_DIR/./sub/../seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "\`.\`/\`..\` staying within the worktree is allowed"
}
test_root_escape_failopen() {
    jq_required || return 0
    # A `..` that would pop past `/` is malformed and cannot be scoped -> fail-open.
    run_guard "$WT_DIR" "Edit" "file_path" "/../etc/passwd"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "a root-escaping .. fails open (allow)"
}
