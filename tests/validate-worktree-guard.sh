#!/usr/bin/env bash
# Coverage for the PreToolUse worktree-scope guard hook
# plugins/workflow/hooks/worktree-guard.sh (issues #475, #501).
#
# #501 extends the guard from the standard topology to per-topology main_root
# derivation from the common-dir PATH STRUCTURE (NOT worktree-writable config): a
# SUBMODULE-vendored worktree leak into the submodule's real checkout is now
# DENIED (was an interim loud fail-open). A BARE-repo host / EXOTIC (e.g.
# separate-git-dir) gitdir cannot be scoped from the path alone, and the only
# remaining discriminator (core.bare) is worktree-poisonable, so a CROSS-TREE
# target there fails open LOUDLY — while the host's own-worktree edits pass the
# topology-independent worktree-first allow silently. Because the derivation must
# survive the golem poisoning core.bare/core.worktree in the shared config (two
# #501 pre-PR review CRITICALs, dynamic-repro'd), dedicated poison + stray-
# misconfig + separate-git-dir cases assert no such write yields a silent allow.
# (One trust-anchor gap is NOT closed here and is tracked as a follow-up: a golem
# rewriting its own $WT/.git gitlink defeats the #475 main-session identity gate —
# out of #501's topology scope.) Cases below.
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

test_suite "worktree-guard.sh PreToolUse hook (#475, #501)"

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
FIXTURE="$(command mktemp -d)"
trap 'command rm -rf "$FIXTURE"' EXIT
MAIN_DIR="$FIXTURE/repo"
command mkdir -p "$MAIN_DIR"
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

# --- Submodule fixture (#475 pre-PR review finding #1) ----------------------
# In a submodule-vendored deployment, git-common-dir is <super>/.git/modules/<n>,
# whose parent is a git-internal dir, NOT the submodule's checkout root. Deriving
# main_root from parent-of-common would MIS-SCOPE and silently ALLOW a real leak,
# so the guard fails open LOUDLY for this topology instead. Build it so the test
# can assert that (skips cleanly if submodule wiring is unavailable in the env).
SM_OK=0
SM_SUPER=""
SM_WT=""
SM_SUB=""
if _sub_src="$FIXTURE/sub_src" && command mkdir -p "$_sub_src" &&
    git_clean -C "$_sub_src" init -q 2>/dev/null &&
    git_clean -C "$_sub_src" config user.email "test@example.com" &&
    git_clean -C "$_sub_src" config user.name "Test" &&
    { printf 'x\n' >"$_sub_src/f"; } &&
    git_clean -C "$_sub_src" add f 2>/dev/null &&
    git_clean -C "$_sub_src" -c commit.gpgsign=false commit -qm s 2>/dev/null; then
    SM_SUPER="$FIXTURE/outer"
    command mkdir -p "$SM_SUPER"
    if git_clean -C "$SM_SUPER" init -q 2>/dev/null &&
        git_clean -C "$SM_SUPER" config user.email "test@example.com" &&
        git_clean -C "$SM_SUPER" config user.name "Test" &&
        git_clean -C "$SM_SUPER" -c protocol.file.allow=always \
            -c commit.gpgsign=false submodule add -q "$_sub_src" sub 2>/dev/null &&
        git_clean -C "$SM_SUPER" -c commit.gpgsign=false commit -qm add-sub 2>/dev/null &&
        git_clean -C "$SM_SUPER/sub" worktree add -q -b feature/issue-20 \
            "$SM_SUPER/sub_wt20" >/dev/null 2>&1; then
        SM_SUPER="$(cd "$SM_SUPER" && pwd)"
        SM_WT="$(cd "$SM_SUPER/sub_wt20" && pwd)"
        SM_SUB="$SM_SUPER/sub"
        SM_OK=1
    fi
fi

# --- Bare-repo worktree-host fixture (#501) ---------------------------------
# A bare repo has NO working tree of its own, so a linked-worktree session there
# has no "main checkout" for an edit to leak INTO — the worktree-escaping-leak
# class is structurally impossible. The guard must ALLOW (a correct allow), and —
# unlike the interim submodule fail-open — do so WITHOUT a loud diagnostic (there
# is nothing degraded about it). Build `bare.git` (core.bare=true) + a linked
# worktree; skip cleanly if bare-worktree wiring is unavailable in the env.
BARE_OK=0
BARE_GITDIR=""
BARE_WT=""
if _bseed="$FIXTURE/bare_seed" && command mkdir -p "$_bseed" &&
    git_clean -C "$_bseed" init -q 2>/dev/null &&
    git_clean -C "$_bseed" config user.email "test@example.com" &&
    git_clean -C "$_bseed" config user.name "Test" &&
    { printf 'a\n' >"$_bseed/a"; } &&
    git_clean -C "$_bseed" add a 2>/dev/null &&
    git_clean -C "$_bseed" -c commit.gpgsign=false commit -qm a 2>/dev/null &&
    git_clean clone -q --bare "$_bseed" "$FIXTURE/bare.git" 2>/dev/null &&
    git_clean -C "$FIXTURE/bare.git" worktree add -q -b feature/issue-30 \
        "$FIXTURE/bare_wt30" >/dev/null 2>&1; then
    BARE_GITDIR="$(cd "$FIXTURE/bare.git" && pwd)"
    BARE_WT="$(cd "$FIXTURE/bare_wt30" && pwd)"
    BARE_OK=1
fi

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
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        command ln -sf "$REAL_GIT" "$stub/git"
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

# --- Config-poisoning: the guard's trust anchor must be non-poisonable --------
# #501 pre-PR review (CRITICAL, dynamic repro): the topology derivation must NOT
# trust core.bare/core.worktree read live from the SHARED common-dir config,
# because the golem worktree session this guard polices can rewrite those keys
# (`git config core.bare true` / `core.worktree <decoy>` from its own cwd write
# into the shared config — core.* is not worktree-scoped). If it did, a two-line
# command would flip the guard into a silent-allow (bare branch) or redirect
# main_root to a decoy, disabling the #475/#501 control. The fix derives topology
# from the common-dir PATH STRUCTURE, which `git config` cannot relocate. These
# tests POISON the config from the worktree, then assert the leak is STILL denied.
test_poison_core_bare_still_denies() {
    jq_required || return 0
    # Fresh main+worktree fixture so poisoning does not disturb the shared ones.
    local pdir="$FIXTURE/poison_bare" pmain pwt
    command mkdir -p "$pdir" || {
        skip_test "poison fixture setup failed"
        return 0
    }
    pmain="$pdir/repo"
    command mkdir -p "$pmain"
    git_clean -C "$pmain" init -q 2>/dev/null || {
        skip_test "poison fixture git init failed"
        return 0
    }
    git_clean -C "$pmain" config user.email "test@example.com"
    git_clean -C "$pmain" config user.name "Test"
    printf 'seed\n' >"$pmain/seed.txt"
    git_clean -C "$pmain" add seed.txt 2>/dev/null
    git_clean -C "$pmain" -c commit.gpgsign=false commit -qm seed 2>/dev/null
    pwt="$pmain/.worktrees/issue-99"
    git_clean -C "$pmain" worktree add -q -b feature/issue-99 "$pwt" >/dev/null 2>&1 || {
        skip_test "poison fixture worktree add failed"
        return 0
    }
    pmain="$(cd "$pmain" && pwd)"
    pwt="$(cd "$pwt" && pwd)"
    # ATTACK: set core.bare=true from the worktree cwd (writes the shared config).
    git_clean -C "$pwt" config core.bare true 2>/dev/null || true
    # The leak into the real main checkout must STILL be denied (structure wins).
    run_guard "$pwt" "Edit" "file_path" "$pmain/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "core.bare=true poison does NOT flip the guard to a silent allow"
}
test_poison_core_worktree_still_denies() {
    jq_required || return 0
    local pdir="$FIXTURE/poison_wt" pmain pwt pdecoy
    command mkdir -p "$pdir" || {
        skip_test "poison fixture setup failed"
        return 0
    }
    pmain="$pdir/repo"
    command mkdir -p "$pmain"
    git_clean -C "$pmain" init -q 2>/dev/null || {
        skip_test "poison fixture git init failed"
        return 0
    }
    git_clean -C "$pmain" config user.email "test@example.com"
    git_clean -C "$pmain" config user.name "Test"
    printf 'seed\n' >"$pmain/seed.txt"
    git_clean -C "$pmain" add seed.txt 2>/dev/null
    git_clean -C "$pmain" -c commit.gpgsign=false commit -qm seed 2>/dev/null
    pwt="$pmain/.worktrees/issue-98"
    git_clean -C "$pmain" worktree add -q -b feature/issue-98 "$pwt" >/dev/null 2>&1 || {
        skip_test "poison fixture worktree add failed"
        return 0
    }
    pmain="$(cd "$pmain" && pwd)"
    pwt="$(cd "$pwt" && pwd)"
    pdecoy="$pdir/decoy"
    command mkdir -p "$pdecoy"
    # ATTACK: redirect core.worktree to a decoy from the worktree cwd.
    git_clean -C "$pwt" config core.worktree "$pdecoy" 2>/dev/null || true
    run_guard "$pwt" "Edit" "file_path" "$pmain/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "core.worktree decoy poison does NOT redirect main_root away from the real leak"
}
# #501 cycle-3 CRITICAL (dynamic repro): a worktree-scoped core.worktree override
# (`extensions.worktreeConfig=true` + `git config --worktree core.worktree <main>`,
# both writable from the worktree cwd) redirects `rev-parse --show-toplevel` onto
# the MAIN checkout, which — if trusted for worktree_root — makes the worktree-first
# allow match main-checkout targets and SILENTLY ALLOW a leak. The fix derives
# worktree_root structurally from the gitdir pointer file + cross-checks cwd, so
# the leak must STILL be denied after this poison.
test_poison_worktree_config_toplevel_still_denies() {
    jq_required || return 0
    local pdir="$FIXTURE/poison_wtcfg" pmain pwt
    command mkdir -p "$pdir" || {
        skip_test "worktreeConfig poison fixture setup failed"
        return 0
    }
    pmain="$pdir/repo"
    command mkdir -p "$pmain"
    git_clean -C "$pmain" init -q 2>/dev/null || {
        skip_test "worktreeConfig poison fixture git init failed"
        return 0
    }
    git_clean -C "$pmain" config user.email "test@example.com"
    git_clean -C "$pmain" config user.name "Test"
    printf 'seed\n' >"$pmain/seed.txt"
    git_clean -C "$pmain" add seed.txt 2>/dev/null
    git_clean -C "$pmain" -c commit.gpgsign=false commit -qm seed 2>/dev/null
    pwt="$pmain/.worktrees/issue-96"
    git_clean -C "$pmain" worktree add -q -b feature/issue-96 "$pwt" >/dev/null 2>&1 || {
        skip_test "worktreeConfig poison fixture worktree add failed"
        return 0
    }
    pmain="$(cd "$pmain" && pwd)"
    pwt="$(cd "$pwt" && pwd)"
    # ATTACK: turn on worktree config and redirect this worktree's toplevel to main.
    git_clean -C "$pwt" config extensions.worktreeConfig true 2>/dev/null || true
    git_clean -C "$pwt" config --worktree core.worktree "$pmain" 2>/dev/null || true
    # Sanity: confirm the attack actually redirected show-toplevel (else the test
    # would vacuously pass without exercising the vector).
    local redirected
    redirected="$(git_clean -C "$pwt" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$redirected" != "$pmain" ]; then
        skip_test "extensions.worktreeConfig unsupported in this git version"
        return 0
    fi
    run_guard "$pwt" "Edit" "file_path" "$pmain/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "worktreeConfig core.worktree toplevel redirect does NOT silence a leak (structural worktree_root + cwd cross-check)"
}

# --- Stray core.bare on a real working checkout must NOT silence a leak -------
# #501 review (MEDIUM, the documented core.bare-misconfig class): a stray
# core.bare=true left on a NORMAL checkout (not a real bare host) must not flip
# the guard to the silent bare-allow. Structural derivation keys off the `*/.git`
# common-dir path, so the standard arm still wins here. (Same shape as the poison
# test, framed as an accidental misconfig rather than an attack.)
test_stray_core_bare_misconfig_still_denies() {
    jq_required || return 0
    local pdir="$FIXTURE/stray_bare" pmain pwt
    command mkdir -p "$pdir" || {
        skip_test "stray-bare fixture setup failed"
        return 0
    }
    pmain="$pdir/repo"
    command mkdir -p "$pmain"
    git_clean -C "$pmain" init -q 2>/dev/null || {
        skip_test "stray-bare fixture git init failed"
        return 0
    }
    git_clean -C "$pmain" config user.email "test@example.com"
    git_clean -C "$pmain" config user.name "Test"
    printf 'seed\n' >"$pmain/seed.txt"
    git_clean -C "$pmain" add seed.txt 2>/dev/null
    git_clean -C "$pmain" -c commit.gpgsign=false commit -qm seed 2>/dev/null
    pwt="$pmain/.worktrees/issue-97"
    git_clean -C "$pmain" worktree add -q -b feature/issue-97 "$pwt" >/dev/null 2>&1 || {
        skip_test "stray-bare fixture worktree add failed"
        return 0
    }
    pmain="$(cd "$pmain" && pwd)"
    pwt="$(cd "$pwt" && pwd)"
    # Stray misconfig written directly into the shared top-level .git config.
    git_clean -C "$pwt" config -f "$pmain/.git/config" core.bare true 2>/dev/null || true
    run_guard "$pwt" "Edit" "file_path" "$pmain/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "stray core.bare=true on a real checkout does NOT silence a leak (structural */.git wins)"
}

# --- Bare-repo host topology (#501) -----------------------------------------
# A bare-repo worktree host has no main working tree. Two behaviours:
#   1. The host's own linked-worktree files pass the TOPOLOGY-INDEPENDENT
#      worktree-first allow SILENTLY — no derivation, no diagnostic.
#   2. A CROSS-TREE target (e.g. into the bare gitdir itself) reaches the residual
#      derivation branch, whose only bare-vs-exotic discriminator (`core.bare` /
#      `--is-bare-repository`) is worktree-POISONABLE — so #501 refuses to trust it
#      and FAILS OPEN LOUDLY (cycle-2 review CRITICAL: a `git config core.bare true`
#      from a separate-git-dir worktree otherwise flipped a loud fail-open into a
#      SILENT allow). The bare host loses nothing real: its legitimate edits are
#      case 1; only a genuinely cross-tree target lands here, worth a diagnostic.
test_bare_host_own_worktree_allows_silently() {
    jq_required || return 0
    if [ "$BARE_OK" -ne 1 ]; then
        skip_test "bare-repo-host fixture unavailable in this environment"
        return 0
    fi
    run_guard "$BARE_WT" "Edit" "file_path" "$BARE_WT/a"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "bare-host worktree's own path allowed"
    local err
    err="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/a"}}' "$BARE_WT" "$BARE_WT" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_output_empty "$err" "bare-host own-worktree allow is silent (worktree-first, no diagnostic)"
}
test_bare_host_cross_tree_failopen_is_loud() {
    if [ "$BARE_OK" -ne 1 ]; then
        skip_test "bare-repo-host fixture unavailable in this environment"
        return 0
    fi
    local payload err out
    payload="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/hooks/x"}}' \
        "$BARE_WT" "$BARE_GITDIR")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_contains "$err" "worktree-scope not derivable" "bare-host cross-tree target fails open with a LOUD diagnostic"
    assert_output_empty "$out" "bare-host cross-tree fail-open emits no deny envelope"
}

# --- Exotic / separate-git-dir gitdir: cross-tree fails open LOUDLY, immune to
# --- core.bare poisoning (#501 cycle-2 CRITICAL) -----------------------------
# A `git init --separate-git-dir=<store>` main checkout gives a common-dir that
# matches neither `*/.git` nor `*/.git/modules/*` — the residual branch. #501 must
# fail open LOUDLY there, AND must NOT be flippable to a silent allow by a
# worktree-side `git config core.bare true` (the exact cycle-2 repro). This is the
# genuinely-exotic case, built from a real git feature (not a hand-mangled gitdir).
_exotic_sgd_fixture() {
    # Sets EX_MAIN / EX_WT / EX_STORE; returns 1 (skip) if the env can't build it.
    EX_ROOT="$FIXTURE/sgd_$1"
    command mkdir -p "$EX_ROOT" || return 1
    EX_MAIN="$EX_ROOT/work"
    EX_STORE="$EX_ROOT/store"
    command mkdir -p "$EX_MAIN" || return 1
    git_clean -C "$EX_MAIN" init -q --separate-git-dir="$EX_STORE" 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" config user.email "test@example.com"
    git_clean -C "$EX_MAIN" config user.name "Test"
    { printf 'x\n' >"$EX_MAIN/seed.txt"; } || return 1
    git_clean -C "$EX_MAIN" add seed.txt 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" -c commit.gpgsign=false commit -qm s 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" worktree add -q -b "feature/issue-$1" "$EX_ROOT/wt" >/dev/null 2>&1 || return 1
    EX_MAIN="$(cd "$EX_MAIN" && pwd)"
    EX_WT="$(cd "$EX_ROOT/wt" && pwd)"
    # Confirm the common-dir really landed in the residual (non-.git, non-module) shape.
    local cd
    cd="$(git_clean -C "$EX_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$cd" in
        "" | */.git | */.git/modules/*) return 1 ;;
    esac
    return 0
}
test_exotic_sgd_cross_tree_failopen_is_loud() {
    if ! _exotic_sgd_fixture 41; then
        skip_test "separate-git-dir fixture unavailable in this environment"
        return 0
    fi
    local payload err out
    payload="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/seed.txt"}}' \
        "$EX_WT" "$EX_MAIN")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_contains "$err" "worktree-scope not derivable" "separate-git-dir cross-tree target fails open LOUDLY"
    assert_output_empty "$out" "separate-git-dir cross-tree fail-open emits no deny envelope"
}
test_exotic_sgd_core_bare_poison_stays_loud() {
    if ! _exotic_sgd_fixture 42; then
        skip_test "separate-git-dir fixture unavailable in this environment"
        return 0
    fi
    # ATTACK (cycle-2 repro): poison core.bare from the worktree cwd. The residual
    # branch must STILL fail open LOUDLY, never flip to a silent allow.
    git_clean -C "$EX_WT" config core.bare true 2>/dev/null || true
    local payload err out
    payload="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/seed.txt"}}' \
        "$EX_WT" "$EX_MAIN")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_contains "$err" "worktree-scope not derivable" "core.bare poison does NOT silence the exotic fail-open (stays loud)"
    assert_output_empty "$out" "core.bare poison emits no deny envelope but also no silent-allow regression"
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
run_test test_deny_dotdot_into_main "review2: \$WT/.. into main is denied (normalized)"
run_test test_allow_dot_within_worktree "review2: ./.. within worktree allowed"
run_test test_root_escape_failopen "review2: root-escaping .. fails open"
run_test test_submodule_deny_leak "#501: submodule leak into real checkout is DENIED"
run_test test_submodule_allow_own_worktree "#501: submodule worktree's own path allowed"
run_test test_submodule_poison_still_denies "#501: submodule config poison does NOT disarm"
run_test test_poison_core_bare_still_denies "#501: core.bare=true poison still denies (non-poisonable)"
run_test test_poison_core_worktree_still_denies "#501: core.worktree decoy poison still denies"
run_test test_poison_worktree_config_toplevel_still_denies "#501: worktreeConfig toplevel redirect still denies"
run_test test_stray_core_bare_misconfig_still_denies "#501: stray core.bare misconfig still denies"
run_test test_bare_host_own_worktree_allows_silently "#501: bare-host own worktree allowed silently"
run_test test_bare_host_cross_tree_failopen_is_loud "#501: bare-host cross-tree fails open LOUDLY"
run_test test_exotic_sgd_cross_tree_failopen_is_loud "#501: separate-git-dir cross-tree fails open LOUDLY"
run_test test_exotic_sgd_core_bare_poison_stays_loud "#501: core.bare poison stays loud (no silent-allow)"
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
