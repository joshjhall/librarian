#!/usr/bin/env bash
# Coverage for the PreToolUse worktree-scope guard hook
# plugins/workflow/hooks/worktree-guard.sh (issue #475).
#
# The guard blocks a golem worktree session from editing a MAIN-CHECKOUT path
# (the silent absolute-path leak that can revert a merged PR), while never
# blocking the main session or legitimate worktree/out-of-repo edits. The
# behaviours that carry the risk a silent regression would ship unnoticed:
#   1. POSITIVE-BLOCK — a worktree session (git-dir != git-common-dir) editing a
#      path under the MAIN checkout but outside its worktree must be DENIED. A
#      scoping regression that turned the guard into a permanent no-op would
#      silently defeat the control; the block-case assertions fail CI if it does.
#   2. WORKTREE + MAIN SAFETY — an edit to the CORRECT worktree path, and any
#      edit from the MAIN session (git-dir == git-common-dir), must be ALLOWED. A
#      guard that blocked either would break the happy path.
#   3. OUT-OF-REPO / RELATIVE carve-out — an absolute target outside the repo
#      (/tmp, $HOME/...) or a relative target must be ALLOWED (not this guard's
#      concern; a relative path resolves against the worktree cwd).
#
# Unlike bash-guard (which needs no git), the discriminator here is git-worktree
# scope, so each case runs against a REAL on-disk fixture: a `git init` sandbox
# (the "main" checkout) plus a real linked worktree via `git worktree add`. The
# payload's `cwd` selects which side the call comes from. git's hook-exported
# environment (GIT_DIR/GIT_COMMON_DIR/…) is scrubbed so it cannot pin the hook's
# `git -C "$cwd"` to this OUTER repo — same GIT_SCRUB convention as
# validate-golem-scripts.sh.
#
# The guard's decision travels in its STDOUT JSON (permissionDecision deny) or
# its absence (allow), not the exit code (always 0). The no-jq path is exercised
# via a PATH-stub (bash + git only) to prove the pure-bash fallback still
# enforces #1 and preserves #2. A hooks.json-integrity block asserts the guard
# is actually registered.
#
# Pure bash + coreutils (+ jq for decision parsing, which skips cleanly when jq
# is absent), reached via absolute /usr/bin/* paths per project convention. Uses
# the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/plugins/workflow/hooks/worktree-guard.sh"
HOOKS_JSON="$REPO_ROOT/plugins/workflow/hooks/hooks.json"

# Resolve the real bash + git once so the no-jq case (which strips PATH) still
# finds an interpreter and git.
REAL_BASH="$(command -v bash)"
REAL_GIT="$(command -v git)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "worktree-guard.sh PreToolUse hook (#475)"

# git env that must NOT leak into the fixture or the hook's own `git -C` — else
# the OUTER repo's GIT_DIR pins scope to the wrong tree. Held as an array so the
# `${arr[@]/#/--unset=}` expansion (bash-3.2 clean) yields one arg per var — the
# same idiom validate-golem-scripts.sh uses.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# git_clean <args...> — run git with the hook-exported env scrubbed.
git_clean() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_GIT" "$@"
}

# --- Fixture: a main checkout + a real linked worktree ----------------------
# MAIN_DIR is the primary checkout; WT_DIR is a linked worktree of it. Both are
# real on disk so the hook's `git -C "$cwd" rev-parse` returns true roots.
FIXTURE="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$FIXTURE"' EXIT
MAIN_DIR="$FIXTURE/repo"
/usr/bin/mkdir -p "$MAIN_DIR"
git_clean -C "$MAIN_DIR" init -q
git_clean -C "$MAIN_DIR" config user.email "test@example.com"
git_clean -C "$MAIN_DIR" config user.name "Test"
printf 'seed\n' >"$MAIN_DIR/seed.txt"
git_clean -C "$MAIN_DIR" add seed.txt
git_clean -C "$MAIN_DIR" -c commit.gpgsign=false commit -qm seed
# Linked worktree at repo/.worktrees/issue-1 on a new branch.
WT_DIR="$MAIN_DIR/.worktrees/issue-1"
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-1 "$WT_DIR" >/dev/null 2>&1

# Canonicalize (mktemp under /tmp may be a symlink to /private/tmp on macOS); the
# hook resolves roots with `cd … && pwd`, so compare against the same.
MAIN_DIR="$(cd "$MAIN_DIR" && pwd)"
WT_DIR="$(cd "$WT_DIR" && pwd)"

# --- Runner -----------------------------------------------------------------
# run_guard <cwd> <tool> <path-field> <path> [nojq] — build a PreToolUse payload
# and pipe it to the REAL hook with git env scrubbed; capture stdout in
# GUARD_OUT. In "nojq" mode the child runs under a PATH containing only bash+git
# (no jq) to force the pure-bash fallback.
GUARD_OUT=""
run_guard() {
    local cwd="$1" tool="$2" field="$3" path="$4" mode="${5:-}"
    local payload
    payload="$(printf '{"cwd":"%s","tool_name":"%s","tool_input":{"%s":"%s"}}' \
        "$cwd" "$tool" "$field" "$path")"
    if [ "$mode" = "nojq" ]; then
        local stub="$FIXTURE/stub-bin"
        /usr/bin/mkdir -p "$stub"
        /usr/bin/ln -sf "$REAL_BASH" "$stub/bash"
        /usr/bin/ln -sf "$REAL_GIT" "$stub/git"
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    else
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    fi
}

# decision <stdout> — echo the permissionDecision, or "allow" when the hook
# emitted nothing. Requires jq; jq-dependent callers are guarded.
decision() {
    local out="$1"
    if [ -z "$out" ]; then
        printf 'allow\n'
        return 0
    fi
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'parse-error\n'
}

jq_required() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable"
        return 1
    fi
    return 0
}

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
test_allow_dotdot_traversal_failopen() {
    jq_required || return 0
    # A `..` target can't be scoped lexically -> fail-open (allow), loudly.
    run_guard "$WT_DIR" "Edit" "file_path" "$MAIN_DIR/../repo/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" ".. traversal fails open (allow)"
}

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

# --- Dispatch ---------------------------------------------------------------
run_test test_deny_leak_edit "deny: worktree->main leak (Edit)"
run_test test_deny_leak_write_nested "deny: worktree->main leak (nested Write)"
run_test test_deny_leak_notebook "deny: worktree->main leak (NotebookEdit)"
run_test test_deny_reason_names_paths "deny reason names paths + recovery"
run_test test_allow_worktree_path "allow: correct worktree path"
run_test test_allow_worktree_nested_new "allow: new file under the worktree"
run_test test_allow_main_session "main-session: edit of own tree allowed"
run_test test_allow_out_of_repo_tmp "allow: out-of-repo /tmp target"
run_test test_allow_relative_path "allow: relative target"
run_test test_allow_dotdot_traversal_failopen "allow: .. traversal fails open"
run_test test_parse_empty_allows "parse-fail: empty stdin allows"
run_test test_parse_empty_is_loud "parse-fail: empty stdin is loud"
run_test test_parse_nonjson_allows "parse-fail: non-JSON allows"
run_test test_no_target_allows "no target path: allows"
run_test test_nojq_denies_leak "no-jq: still denies a leak"
run_test test_nojq_allows_main "no-jq: still allows a main edit"
run_test test_nojq_allows_worktree "no-jq: still allows the worktree edit"
run_test test_hooks_registered "hooks.json registers the guard"
run_test test_guard_executable "worktree-guard.sh is executable"

generate_report
