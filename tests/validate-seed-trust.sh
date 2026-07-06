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
# sandbox as repo root, never the librarian checkout). Every git call and every
# seed-script invocation is wrapped in `/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"`
# so git's hook-exported environment (GIT_DIR / GIT_COMMON_DIR / …) cannot pin
# the script's repo_root to the OUTER repo when the suite runs from a `git push`
# pre-push hook — the exact failure mode root-caused in golem-gate-watch (PR #62)
# and whose fix this mirrors. All writes are confined to the sandbox; the EXIT
# trap removes it. The real ~/.claude.json is never touched (config path is
# always an in-sandbox file).
#
# Pure bash + coreutils, reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_SCRIPT="$REPO_ROOT/plugins/workflow/scripts/seed-worktree-trust.sh"

# Resolve the real bash once so child invocations work even when PATH is
# deliberately stripped to hide jq (test g).
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment. When this suite runs from a `git push`
# pre-push hook these are set; inherited into a child, they pin every `git` call
# (and the seed script's repo_root) to the OUTER repo, so `git init` / repo_root
# would ignore the sandbox. Scrub all of them per-invocation via
# `/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"` (the documented golem-gate-watch
# fix), never a one-shot module-level `unset` that a re-injected var defeats.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "seed-worktree-trust path validation"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits. Each sandbox is
# a fresh subdir, so no per-test trap is needed (mirrors validate-release.sh).
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# Creates a fresh git repo sandbox with a `.worktrees/` dir and an empty `{}`
# config at <sandbox>/claude.json, assigning the sandbox path to the caller's
# named variable. The `git init` runs with the git environment scrubbed so the
# sandbox is hermetic even under a pre-push hook.
new_sandbox() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$dir/.worktrees"
    /usr/bin/printf '{}\n' >"$dir/claude.json"
    printf -v "$__out" '%s' "$dir"
}

# new_sandbox_with_worktree <varname>
# Like new_sandbox, but also seeds a HEAD commit and adds a real linked sibling
# worktree at <sandbox>/.worktrees/issue-100. Used by the cwd-independence
# regression (#242): `git worktree add` requires a commit, which the plain
# sandbox lacks. All git calls are env-scrubbed so the added worktree is a
# worktree of the SANDBOX, never the outer librarian repo.
new_sandbox_with_worktree() {
    local __out="$1" __sb
    # Pass a caller-unique out-var name to new_sandbox: it has its own internal
    # `local dir`, so reusing that name here would collide (no namerefs on
    # bash 3.2).
    new_sandbox __sb || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$__sb" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$__sb" worktree add -q "$__sb/.worktrees/issue-100" \
        -b feature/issue-100 2>/dev/null || return 1
    printf -v "$__out" '%s' "$__sb"
}

# Captured results of the most recent invocation.
SEED_RC=0
SEED_OUT=""

# run_seed <sandbox-dir> <worktree-path> [config-path]
# Invokes the real script from within the sandbox (so repo_root resolves there),
# with the git environment scrubbed, capturing combined stdout+stderr in
# SEED_OUT and the exit code in SEED_RC. Honors GOLEM_WORKTREE_DIR if the caller
# exported it before calling.
run_seed() {
    local dir="$1" wt="$2" cfg="${3:-$1/claude.json}"
    SEED_RC=0
    SEED_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" "$wt" "$cfg" 2>&1)" || SEED_RC=$?
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
    # A sibling dir under WORKDIR is a real, on-disk path but not under the
    # sandbox root — mirrors the real exploit vector (an existing host dir) and
    # exercises realpath against a path that exists, not just a lexical one.
    outside="$WORKDIR/elsewhere/issue-7"
    /usr/bin/mkdir -p "$outside"
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
    # Confirm the OUTER shape arm fired, not the inner all-digits arm (d).
    assert_not_contains "$SEED_OUT" "not all-digits" \
        "shape arm fired, not the non-digit-suffix arm"
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
    /usr/bin/mkdir -p "$sb/src"
    run_seed "$sb" "$sb/src/issue-7"
    assert_exit 3 "$SEED_RC" "in-repo path outside the worktree dir is refused (exit 3)"
    assert_contains "$SEED_OUT" "is not a" "explains the worktree-dir violation"
}

# (f) Not inside a git repository at all: the first guard (repo_root unresolved)
# refuses with exit 3 before any path check. Run from a plain mktemp dir with no
# `git init` AND the git environment scrubbed, so neither the cwd nor an
# inherited GIT_DIR can supply a repo context.
test_not_in_git_repo_refused() {
    local nogit
    nogit="$(/usr/bin/mktemp -d "$WORKDIR/nogit.XXXXXX")"
    SEED_RC=0
    SEED_OUT="$(cd "$nogit" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" "$nogit/.worktrees/issue-1" \
            "$nogit/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 3 "$SEED_RC" "invocation outside any git repo is refused (exit 3)"
    assert_contains "$SEED_OUT" "not inside a git repository" \
        "reports the missing git context"
}

# (g) Missing argument exits 2 (distinct from the validation refusal code).
test_missing_arg_exits_2() {
    local sb
    new_sandbox sb
    SEED_RC=0
    SEED_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" 2>&1)" || SEED_RC=$?
    assert_exit 2 "$SEED_RC" "no worktree-path argument exits 2"
    assert_contains "$SEED_OUT" "missing worktree path" "reports the missing argument"
}

# (h) Best-effort skip when jq is absent: validation still passes, but the write
# is skipped with exit 0. jq is removed by pointing PATH at a stub dir holding
# ONLY a `bash` symlink (no `jq`), so `command -v jq` fails inside the script —
# the portable, deterministic technique used by golem-gate-watch. BASH_ENV must
# be unset too, or /etc/bash_env re-adds the real PATH on the devcontainer and
# defeats the stub.
test_jq_absent_skips() {
    local sb stub_bin
    new_sandbox sb
    stub_bin="$sb/stub-bin"
    /usr/bin/mkdir -p "$stub_bin"
    /usr/bin/ln -s "$REAL_BASH" "$stub_bin/bash"
    SEED_RC=0
    SEED_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$stub_bin" \
            "$REAL_BASH" "$SEED_SCRIPT" "$sb/.worktrees/issue-9" \
            "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 0 "$SEED_RC" "jq absent → best-effort skip exits 0"
    assert_contains "$SEED_OUT" "skipped trust seed" "reports the skip"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched when the write is skipped"
}

# (i) Best-effort skip when the config file is absent (the other operand of the
# same guard): validation passes, write skipped, exit 0.
test_config_absent_skips() {
    local sb
    new_sandbox sb
    run_seed "$sb" "$sb/.worktrees/issue-9" "$sb/does-not-exist.json"
    assert_exit 0 "$SEED_RC" "absent config → best-effort skip exits 0"
    assert_contains "$SEED_OUT" "skipped trust seed" "reports the skip"
}

# (j) Malformed config: validation passes, jq runs but fails to parse, so the
# write is skipped (config left untouched) with exit 0 — the jq-failure arm.
# Also asserts the temp file (mktemp adjacent to the config) is cleaned up by the
# script's `rm -f` safety net, so a broken cleanup leaves no `${cfg}.XXXXXX`
# litter on every failed-jq invocation.
test_malformed_config_skips() {
    local sb leftover
    new_sandbox sb
    /usr/bin/printf 'not json {{{' >"$sb/claude.json"
    run_seed "$sb" "$sb/.worktrees/issue-9"
    assert_exit 0 "$SEED_RC" "malformed config → jq fails, skip exits 0"
    assert_contains "$SEED_OUT" "could not update" "reports the jq failure"
    assert_file_contains "$sb/claude.json" "not json" \
        "malformed config is left byte-for-byte untouched"
    leftover="$(/usr/bin/find "$sb" -maxdepth 1 -name 'claude.json.*' 2>/dev/null)"
    assert_equals "" "$leftover" "no temp file left beside config after jq failure"
}

# (k) GOLEM_WORKTREE_DIR override: a path under the custom worktree dir validates.
test_worktree_dir_override() {
    local sb
    new_sandbox sb
    /usr/bin/mkdir -p "$sb/custom-wt"
    SEED_RC=0
    SEED_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" GOLEM_WORKTREE_DIR=custom-wt \
            "$REAL_BASH" "$SEED_SCRIPT" "$sb/custom-wt/issue-5" \
            "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 0 "$SEED_RC" "path under GOLEM_WORKTREE_DIR override is accepted"
    assert_contains "$SEED_OUT" "seeded workspace trust" "reports the trust seed"
    assert_file_contains "$sb/claude.json" '"hasTrustDialogAccepted": true' \
        "override path is recorded in the config"
}

# (l) The override REPLACES the default dir, it does not supplement it: with
# GOLEM_WORKTREE_DIR=custom-wt set, a path under the default `.worktrees/` is
# refused. Guards against the override becoming additive (which would widen the
# trusted set beyond the single intended dir).
test_worktree_dir_override_replaces_default() {
    local sb
    new_sandbox sb
    /usr/bin/mkdir -p "$sb/custom-wt"
    SEED_RC=0
    SEED_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" GOLEM_WORKTREE_DIR=custom-wt \
            "$REAL_BASH" "$SEED_SCRIPT" "$sb/.worktrees/issue-5" \
            "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 3 "$SEED_RC" "default .worktrees path is refused when override is set"
    assert_contains "$SEED_OUT" "custom-wt/issue-<N>" \
        "names the active override dir in the refusal"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched on refusal"
}

# (m) Symlink escape: a symlink at `.worktrees/issue-7` pointing OUTSIDE the repo
# is refused. realpath -m canonicalizes the link target before the under-root
# check, so the grant cannot be redirected to an arbitrary host dir via a symlink
# — the core issue-#21 attack surface. A regression in canon()/the prefix check
# would silently re-open it.
test_symlink_escape_refused() {
    local sb target
    new_sandbox sb
    target="$WORKDIR/escape-target"
    /usr/bin/mkdir -p "$target"
    /usr/bin/ln -s "$target" "$sb/.worktrees/issue-7"
    run_seed "$sb" "$sb/.worktrees/issue-7"
    assert_exit 3 "$SEED_RC" "symlink escaping the repo root is refused (exit 3)"
    assert_contains "$SEED_OUT" "not under repo root" \
        "canonicalized link target fails the under-root check"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched on a symlink-escape refusal"
}

# (n) Regression (#242): resolving the repo root must NOT depend on the caller's
# cwd. From inside a DIFFERENT linked worktree of the same repo (the sibling /
# just-reaped-worktree situation during /orchestrate lane refill), a valid
# `issue-<N>` target still seeds trust. The old `--show-toplevel`-first resolver
# returned the sibling worktree's own toplevel here and falsely refused (exit 3);
# repo_root() (git-common-dir parent) resolves the main root regardless of cwd.
test_cwd_independent_root_from_sibling_worktree() {
    local sb
    new_sandbox_with_worktree sb
    SEED_RC=0
    SEED_OUT="$(cd "$sb/.worktrees/issue-100" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" "$sb/.worktrees/issue-7" \
            "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 0 "$SEED_RC" \
        "valid target seeds trust from a sibling-worktree cwd (exit 0, no false refusal)"
    assert_contains "$SEED_OUT" "seeded workspace trust" "reports the trust seed"
    assert_not_contains "$SEED_OUT" "not under repo root" \
        "no false 'not under repo root' refusal from the sibling worktree cwd"
    assert_file_contains "$sb/claude.json" '"hasTrustDialogAccepted": true' \
        "config records the trust grant despite the sibling-worktree cwd"
}

# (o) Regression companion to (n): the REFUSE path must also survive a
# sibling-worktree cwd. A target OUTSIDE the repo, invoked from inside a sibling
# linked worktree, must still be refused (exit 3). Guards the more dangerous
# direction of the resolver swap — repo_root() widening acceptance so an
# out-of-tree target is falsely ACCEPTED — which (n)'s accept-only case can't see.
test_outside_repo_refused_from_sibling_worktree() {
    local sb
    new_sandbox_with_worktree sb
    /usr/bin/mkdir -p "$WORKDIR/elsewhere/issue-7"
    SEED_RC=0
    SEED_OUT="$(cd "$sb/.worktrees/issue-100" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" "$WORKDIR/elsewhere/issue-7" \
            "$sb/claude.json" 2>&1)" || SEED_RC=$?
    assert_exit 3 "$SEED_RC" \
        "out-of-repo target is still refused from a sibling-worktree cwd (exit 3)"
    assert_contains "$SEED_OUT" "not under repo root" "explains the root violation"
    assert_file_not_contains "$sb/claude.json" "hasTrustDialogAccepted" \
        "config is left untouched on refusal from the sibling cwd"
}

# (p) Regression (#242, literal case): cwd is a JUST-REMOVED worktree — the exact
# reaped-worktree situation from the issue. A subshell cds into a linked worktree,
# that worktree is then `git worktree remove`d out from under it, and the seed
# script runs from the now-deleted cwd. getcwd() fails, so git resolves no repo
# and the script refuses cleanly via its FIRST guard ("not inside a git
# repository", exit 3) — it must NOT emit the old false "not under repo root"
# refusal naming a stale worktree root. Trust is (correctly) not seeded here; the
# real-world reap fix is that a FRESH cwd (the caller cds to a stable root) now
# resolves correctly via (n) — this case pins the fail-safe for the degenerate
# deleted-cwd path.
test_removed_worktree_cwd_refuses_cleanly() {
    local sb
    new_sandbox_with_worktree sb
    SEED_RC=0
    SEED_OUT="$( (
        cd "$sb/.worktrees/issue-100" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                /usr/bin/git -C "$sb" worktree remove --force \
                "$sb/.worktrees/issue-100" 2>/dev/null
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$SEED_SCRIPT" "$sb/.worktrees/issue-7" \
            "$sb/claude.json"
    ) 2>&1)" || SEED_RC=$?
    assert_exit 3 "$SEED_RC" "seed from a removed-worktree cwd refuses (exit 3)"
    assert_contains "$SEED_OUT" "not inside a git repository" \
        "degrades via the first guard, not a stale-root false refusal"
    assert_not_contains "$SEED_OUT" "not under repo root" \
        "no false 'not under repo root' naming a since-removed worktree"
}

# (q) SCRIPT_DIR resolution: a bare-name invocation (BASH_SOURCE with no slash,
# e.g. `cd <dir> && bash seed-worktree-trust.sh`) must FAIL LOUD (exit 4) rather
# than fall back to sourcing `$(pwd)/config.sh` — a code-injection vector in a
# trust-boundary script (#21). Proven by planting a config.sh that would `echo
# INJECTED` in the invocation dir and asserting it never runs.
test_bare_name_invocation_refuses() {
    local scriptdir
    scriptdir="$(/usr/bin/mktemp -d "$WORKDIR/barename.XXXXXX")"
    /usr/bin/cp "$SEED_SCRIPT" "$scriptdir/seed-worktree-trust.sh"
    # A config.sh here would be sourced iff the fallback wrongly used $(pwd).
    /usr/bin/printf 'echo INJECTED\n' >"$scriptdir/config.sh"
    SEED_RC=0
    SEED_OUT="$(cd "$scriptdir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" seed-worktree-trust.sh /tmp/x/issue-7 /tmp/x/cfg.json \
            2>&1)" || SEED_RC=$?
    assert_exit 4 "$SEED_RC" "bare-name invocation refuses with exit 4"
    assert_contains "$SEED_OUT" "cannot resolve script dir" "explains the refusal"
    assert_not_contains "$SEED_OUT" "INJECTED" \
        "the cwd config.sh is never sourced (no injection)"
}

# --- Run all tests ----------------------------------------------------------

# Every sandbox is built with `git init`, so the whole suite needs git. Gate it
# from inside a run_test-dispatched body (not a bare module-level skip_test) so
# the counters stay consistent — skip_test is designed for within-test use.
git_unavailable() { ! command -v git >/dev/null 2>&1; }

test_git_available() {
    if git_unavailable; then
        skip_test "git not available — cannot build sandbox repos"
        return
    fi
    assert_true "command -v git" "git is available for sandbox construction"
}

run_test test_git_available "git is available (suite prerequisite)"

if git_unavailable; then
    generate_report
    exit $?
fi

run_test test_valid_path_seeds_trust "valid issue-<N> worktree path seeds trust (exit 0)"
run_test test_outside_repo_root_refused "path outside repo root is refused (exit 3)"
run_test test_wrong_shape_refused "in-tree wrong-shape leaf is refused (exit 3)"
run_test test_non_digit_suffix_refused "issue-<digits><non-digit> suffix is refused (exit 3)"
run_test test_in_repo_wrong_dir_refused "in-repo path outside the worktree dir is refused (exit 3)"
run_test test_not_in_git_repo_refused "invocation outside any git repo is refused (exit 3)"
run_test test_missing_arg_exits_2 "missing worktree-path argument exits 2"
run_test test_jq_absent_skips "jq absent → best-effort skip (exit 0)"
run_test test_config_absent_skips "absent config → best-effort skip (exit 0)"
run_test test_malformed_config_skips "malformed config → jq-failure skip (exit 0)"
run_test test_worktree_dir_override "GOLEM_WORKTREE_DIR override path is accepted (exit 0)"
run_test test_worktree_dir_override_replaces_default "GOLEM_WORKTREE_DIR override replaces the default dir (exit 3)"
run_test test_symlink_escape_refused "symlink escaping the repo root is refused (exit 3)"
run_test test_cwd_independent_root_from_sibling_worktree "valid target seeds trust from a sibling-worktree cwd (#242, exit 0)"
run_test test_outside_repo_refused_from_sibling_worktree "out-of-repo target still refused from a sibling-worktree cwd (#242, exit 3)"
run_test test_removed_worktree_cwd_refuses_cleanly "seed from a since-removed worktree cwd refuses cleanly (#242, exit 3)"
run_test test_bare_name_invocation_refuses "bare-name invocation refuses instead of sourcing cwd config.sh (exit 4)"

generate_report
