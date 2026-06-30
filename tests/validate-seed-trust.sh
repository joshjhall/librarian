#!/usr/bin/env bash
# Coverage for the security-sensitive trust-grant path validation in
# plugins/workflow/scripts/seed-worktree-trust.sh (issue #21, gap filed as #81).
#
# That script seeds a Claude Code workspace-trust entry for a worktree path. The
# write is harmless on its own, but granting trust makes Claude Code load a
# folder's project settings WITHOUT the interactive dialog — so the grant TARGET
# is security-sensitive: a caller able to influence the argument must not be able
# to pre-trust an arbitrary host directory. The script guards this BEFORE the jq
# write by requiring the target to be strictly under THIS repo's root AND to
# match `<GOLEM_WORKTREE_DIR>/issue-<digits>`, refusing with exit 3 otherwise.
#
# None of those paths were exercised by any test. A silent regression here
# re-opens the issue-#21 attack surface with no gate to catch it.
#
# Test shape: each case runs the REAL script inside a fresh `git init` sandbox
# under a module-level `mktemp -d` (so the script's `git rev-parse` resolves the
# sandbox as repo root, never the librarian checkout), with the inherited git
# environment cleared so the parent repo's context cannot leak in. All writes are
# confined to the sandbox; the EXIT trap removes it. The real ~/.claude.json is
# never touched (config path is always an in-sandbox file).
#
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_SCRIPT="$REPO_ROOT/plugins/workflow/scripts/seed-worktree-trust.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "seed-worktree-trust path validation"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits. Each sandbox is
# a fresh subdir, so no per-test trap is needed (mirrors validate-release.sh).
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Clear any inherited git environment so the script's `git rev-parse` binds to
# the sandbox we cd into, not the parent librarian repo. A leaked GIT_DIR was the
# root cause of an earlier flaky gate (golem-gate-watch), so this is deliberate.
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_INDEX_FILE 2>/dev/null || true

# new_sandbox <varname>
# Creates a fresh git repo sandbox with a `.worktrees/` dir and an empty `{}`
# config at <sandbox>/claude.json, assigning the sandbox path to the caller's
# named variable.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    (
        cd "$dir" || exit 1
        /usr/bin/git init -q
    ) || return 1
    command mkdir -p "$dir/.worktrees"
    command printf '{}\n' >"$dir/claude.json"
    printf -v "$__out" '%s' "$dir"
}

# Captured results of the most recent invocation.
SEED_RC=0
SEED_OUT=""

# run_seed <sandbox-dir> <worktree-path> [config-path]
# Invokes the real script from within the sandbox (so repo_root resolves there),
# capturing combined stdout+stderr in SEED_OUT and the exit code in SEED_RC.
# Honors GOLEM_WORKTREE_DIR if the caller exported it.
run_seed() {
    local dir="$1" wt="$2" cfg="${3:-$1/claude.json}"
    SEED_RC=0
    SEED_OUT="$(cd "$dir" && bash "$SEED_SCRIPT" "$wt" "$cfg" 2>&1)" || SEED_RC=$?
}

# --- Tests ------------------------------------------------------------------

# (a) Happy path: a valid `<wt>/issue-<N>` target seeds trust and exits 0.
test_valid_path_seeds_trust() {
    local sb
    new_sandbox sb
    run_seed "$sb" "$sb/.worktrees/issue-7"
    assert_exit 0 "$SEED_RC" "valid issue-7 worktree path exits 0"
    assert_contains "$SEED_OUT" "seeded workspace trust" "reports the trust seed"
    assert_file_contains "$sb/claude.json" '"hasTrustDialogAccepted": true' \
        "config records hasTrustDialogAccepted for the path"
    assert_file_contains "$sb/claude.json" "$sb/.worktrees/issue-7" \
        "config keys the entry on the worktree path"
}

# (b) Target outside the repo root is refused with exit 3.
test_outside_repo_root_refused() {
    local sb outside
    new_sandbox sb
    # A sibling dir under WORKDIR is a real path but not under the sandbox root.
    outside="$WORKDIR/elsewhere/issue-7"
    run_seed "$sb" "$outside"
    assert_exit 3 "$SEED_RC" "path outside repo root is refused (exit 3)"
    assert_contains "$SEED_OUT" "not under repo root" "explains the root violation"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched on refusal"
}

# (c) In-tree but wrong shape (non-`issue-<N>` leaf) is refused — shape arm.
test_wrong_shape_refused() {
    local sb
    new_sandbox sb
    run_seed "$sb" "$sb/.worktrees/issue-abc"
    assert_exit 3 "$SEED_RC" "issue-abc (no leading digit) is refused (exit 3)"
    assert_contains "$SEED_OUT" "is not a" "explains the shape violation"
    assert_contains "$SEED_OUT" "worktree" "names the expected worktree shape"
}

# (d) `issue-<digits><non-digit>` is refused by the inner all-digits check — a
# DISTINCT arm from (c): the leaf matches `issue-[0-9]*` but the suffix is not
# all digits.
test_non_digit_suffix_refused() {
    local sb
    new_sandbox sb
    run_seed "$sb" "$sb/.worktrees/issue-7x"
    assert_exit 3 "$SEED_RC" "issue-7x (trailing non-digit) is refused (exit 3)"
    assert_contains "$SEED_OUT" "not all-digits" "explains the suffix violation"
}

# (e) In-repo but not under the worktree dir is refused — shape arm, in-tree.
test_in_repo_wrong_dir_refused() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/src"
    run_seed "$sb" "$sb/src/issue-7"
    assert_exit 3 "$SEED_RC" "in-repo path outside the worktree dir is refused (exit 3)"
    assert_contains "$SEED_OUT" "is not a" "explains the worktree-dir violation"
}

# (f) Missing argument exits 2 (distinct from the validation refusal code).
test_missing_arg_exits_2() {
    local sb
    new_sandbox sb
    SEED_RC=0
    SEED_OUT="$(cd "$sb" && bash "$SEED_SCRIPT" 2>&1)" || SEED_RC=$?
    assert_exit 2 "$SEED_RC" "no worktree-path argument exits 2"
    assert_contains "$SEED_OUT" "missing worktree path" "reports the missing argument"
}

# (g) Best-effort skip when jq is absent: validation still passes, but the write
# is skipped with exit 0. jq is removed by running with an empty PATH; BASH_ENV
# must be cleared or /etc/bash_env re-adds PATH on the devcontainer.
test_jq_absent_skips() {
    local sb
    new_sandbox sb
    SEED_RC=0
    SEED_OUT="$(cd "$sb" && env -u BASH_ENV PATH=/var/empty /bin/bash \
        "$SEED_SCRIPT" "$sb/.worktrees/issue-9" "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 0 "$SEED_RC" "jq absent → best-effort skip exits 0"
    assert_contains "$SEED_OUT" "skipped trust seed" "reports the skip"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched when the write is skipped"
}

# (h) Best-effort skip when the config file is absent (the other operand of the
# same guard): validation passes, write skipped, exit 0.
test_config_absent_skips() {
    local sb
    new_sandbox sb
    run_seed "$sb" "$sb/.worktrees/issue-9" "$sb/does-not-exist.json"
    assert_exit 0 "$SEED_RC" "absent config → best-effort skip exits 0"
    assert_contains "$SEED_OUT" "skipped trust seed" "reports the skip"
}

# (i) Malformed config: validation passes, jq runs but fails to parse, so the
# write is skipped (config left untouched) with exit 0 — the jq-failure arm.
test_malformed_config_skips() {
    local sb
    new_sandbox sb
    command printf 'not json {{{' >"$sb/claude.json"
    run_seed "$sb" "$sb/.worktrees/issue-9"
    assert_exit 0 "$SEED_RC" "malformed config → jq fails, skip exits 0"
    assert_contains "$SEED_OUT" "could not update" "reports the jq failure"
    assert_file_contains "$sb/claude.json" "not json" \
        "malformed config is left byte-for-byte untouched"
}

# (j) GOLEM_WORKTREE_DIR override: a path under the custom worktree dir validates.
test_worktree_dir_override() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/custom-wt"
    SEED_RC=0
    SEED_OUT="$(cd "$sb" && GOLEM_WORKTREE_DIR=custom-wt bash "$SEED_SCRIPT" \
        "$sb/custom-wt/issue-5" "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 0 "$SEED_RC" "path under GOLEM_WORKTREE_DIR override is accepted"
    assert_contains "$SEED_OUT" "seeded workspace trust" "reports the trust seed"
    assert_file_contains "$sb/claude.json" '"hasTrustDialogAccepted": true' \
        "override path is recorded in the config"
}

# --- Run all tests ----------------------------------------------------------

if ! command -v git >/dev/null 2>&1; then
    skip_test "git not available — cannot build sandbox repos"
    generate_report
    exit $?
fi

run_test test_valid_path_seeds_trust "valid issue-<N> worktree path seeds trust (exit 0)"
run_test test_outside_repo_root_refused "path outside repo root is refused (exit 3)"
run_test test_wrong_shape_refused "in-tree wrong-shape leaf is refused (exit 3)"
run_test test_non_digit_suffix_refused "issue-<digits><non-digit> suffix is refused (exit 3)"
run_test test_in_repo_wrong_dir_refused "in-repo path outside the worktree dir is refused (exit 3)"
run_test test_missing_arg_exits_2 "missing worktree-path argument exits 2"
run_test test_jq_absent_skips "jq absent → best-effort skip (exit 0)"
run_test test_config_absent_skips "absent config → best-effort skip (exit 0)"
run_test test_malformed_config_skips "malformed config → jq-failure skip (exit 0)"
run_test test_worktree_dir_override "GOLEM_WORKTREE_DIR override path is accepted (exit 0)"

generate_report
