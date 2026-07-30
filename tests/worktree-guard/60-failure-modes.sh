# shellcheck shell=bash
# Failure modes and integrity — worktree-scope guard tests (issue #564 split).
#
# Covers parse failure failing open and LOUD, the no-jq fallback still enforcing the core safety properties, and hooks.json integrity.
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

# --- Parse-failure: fail-open + loud ----------------------------------------
test_parse_empty_allows() {
    local out
    out="$(printf '' | "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "empty stdin emits no deny (allow)"
}
test_parse_empty_is_loud() {
    local err
    err="$(printf '' | "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_contains "$err" "worktree-guard" "empty stdin logs a loud diagnostic"
}
test_parse_nonjson_allows() {
    local out
    out="$(printf 'not json' | "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "non-JSON stdin allows"
}
test_no_target_allows() {
    jq_required || return 0
    # A parsed payload with no file_path/notebook_path -> nothing to scope.
    local out
    out="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{}}' "$WT_DIR" |
        "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "payload with no target path allows"
}

# --- No-jq fallback still enforces core safety properties --------------------
test_nojq_denies_leak() {
    run_guard "$WT_DIR" "Edit" "file_path" "$MAIN_DIR/seed.txt" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' "no-jq path still denies a worktree->main leak"
}
test_nojq_allows_main() {
    run_guard "$MAIN_DIR" "Edit" "file_path" "$MAIN_DIR/seed.txt" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path allows a main-session edit"
}
test_nojq_allows_worktree() {
    run_guard "$WT_DIR" "Edit" "file_path" "$WT_DIR/seed.txt" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path allows the correct worktree edit"
}

# --- hooks.json integrity ---------------------------------------------------
test_hooks_registered() {
    jq_required || return 0
    assert_file_exists "$HOOKS_JSON" "hooks.json exists"
    local ok
    ok="$(jq -r '
        (.hooks.PreToolUse // [])
        | map(select((.matcher // "" | test("Edit"))
              and ((.hooks // []) | any(.command | test("worktree-guard\\.sh")))))
        | length' "$HOOKS_JSON" 2>/dev/null || echo 0)"
    assert_equals "1" "$ok" "hooks.json registers a PreToolUse Edit/Write matcher invoking worktree-guard.sh"
}
test_guard_executable() {
    assert_true "[ -x \"$GUARD\" ]" "worktree-guard.sh is executable"
}
