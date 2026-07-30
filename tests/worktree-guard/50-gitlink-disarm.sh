# shellcheck shell=bash
# Gitlink-rewrite disarm — worktree-scope guard tests (issue #564 split).
#
# Covers a golem rewriting $WT/.git to forge a main-session verdict; the guard must walk up structurally rather than trust --show-toplevel (#506).
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

# --- Gitlink-rewrite disarm (#506) ------------------------------------------
# A golem can overwrite its OWN `$WT/.git` gitlink FILE to point at a decoy repo it
# `git init`s, after which `git -C $cwd rev-parse --git-dir` and `--git-common-dir`
# BOTH resolve to the decoy (git-dir == common-dir) — forging the "main session,
# never block" identity gate and disarming the guard for the whole session. #506
# closes it: the identity gate cross-checks whether an OUTERMOST enclosing genuine
# primary (a structural anchor ABOVE the worktree the golem cannot forge) owns cwd,
# and if so re-derives scope and ENFORCES. Two compounding vectors are covered too:
# deleting the external worktree registry (a Bash `rm` the main loop can run) must
# not reopen the hole, and a nearer decoy `git init`ed at a writable ancestor must
# not shrink main_root. The disarming write to `$WT/.git` is ALSO denied outright.
#
# `_gitlink_fixture <slug>` builds a fresh main+worktree under $FIXTURE and sets
# GL_MAIN/GL_WT; returns 1 (skip) if the env can't build it.
_gitlink_fixture() {
    local pdir="$FIXTURE/gl_$1" pmain pwt
    command mkdir -p "$pdir" || return 1
    pmain="$pdir/repo"
    command mkdir -p "$pmain"
    git_clean -C "$pmain" init -q 2>/dev/null || return 1
    git_clean -C "$pmain" config user.email "test@example.com"
    git_clean -C "$pmain" config user.name "Test"
    printf 'seed\n' >"$pmain/seed.txt"
    git_clean -C "$pmain" add seed.txt 2>/dev/null || return 1
    git_clean -C "$pmain" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    pwt="$pmain/.worktrees/issue-$1"
    git_clean -C "$pmain" worktree add -q -b "feature/issue-$1" "$pwt" >/dev/null 2>&1 || return 1
    GL_MAIN="$(cd "$pmain" && pwd)"
    GL_WT="$(cd "$pwt" && pwd)"
    return 0
}
# Rewrite $GL_WT/.git to a decoy repo `git init`ed inside the worktree — the core
# disarm. Confirm the poison actually forged the identity (git-dir == common-dir)
# so a test can't vacuously pass.
_gitlink_poison() {
    git_clean -C "$GL_WT" init -q decoy 2>/dev/null || return 1
    printf 'gitdir: %s/decoy/.git\n' "$GL_WT" >"$GL_WT/.git" || return 1
    local gd cm
    gd="$(git_clean -C "$GL_WT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    cm="$(git_clean -C "$GL_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$gd" ] && [ "$gd" = "$cm" ] # poison succeeded iff the identity is forged
}
test_gitlink_poison_denies_leak() {
    jq_required || return 0
    if ! _gitlink_fixture 506; then
        skip_test "gitlink fixture unavailable in this environment"
        return 0
    fi
    if ! _gitlink_poison; then
        skip_test "gitlink poison did not forge the identity in this git version"
        return 0
    fi
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_valid_json "$GUARD_OUT" "gitlink-poison deny output is valid JSON"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "gitlink-rewrite decoy does NOT disarm the guard (leak into main stays DENIED)"
    # The disguised path re-derives main_root/worktree_root from scratch, so assert
    # the reason names the REAL paths (not a degenerate root collapsed onto cwd or a
    # decoy) — a wrong derivation could still emit `deny` on a stray target.
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    assert_contains "$reason" "$GL_MAIN/seed.txt" "disguised deny reason names the leaked main path"
    assert_contains "$reason" "$GL_WT" "disguised deny reason names the true worktree root (not collapsed to cwd/decoy)"
    assert_contains "$reason" "checkout --" "disguised deny reason gives the restore-only recovery command"
}
# The CRITICAL vector (#506 pre-PR review, dynamic-repro): the anti-disguise anchor
# must not itself read a worktree-poisonable signal. Poisoning core.worktree /
# core.bare in the SHARED config (writable from the worktree cwd, no --worktree
# needed) redirects/blanks `git rev-parse --show-toplevel` on the real main — which
# an earlier draft trusted, re-opening the leak. The structural `-d <a>/.git`
# anchor ignores both keys, so the leak stays DENIED after the poison.
test_gitlink_poison_core_worktree_still_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 507 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    local decoy="$FIXTURE/gl_507/decoy_wt"
    command mkdir -p "$decoy" 2>/dev/null || true
    # Redirect the REAL main's toplevel via the shared config (the exact signal the
    # structural anchor must NOT consult).
    git_clean -C "$GL_WT" config core.worktree "$decoy" 2>/dev/null || true
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "gitlink + core.worktree redirect does NOT disarm (structural -d <a>/.git anchor ignores core.worktree)"
}
test_gitlink_poison_core_bare_still_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 508 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    # core.bare=true blanks the real main's `--show-toplevel` ("must be run in a
    # work tree"); the structural anchor is immune.
    git_clean -C "$GL_WT" config core.bare true 2>/dev/null || true
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "gitlink + core.bare=true poison does NOT disarm (structural anchor ignores core.bare)"
}
# The disguise also works by `git init`ing the worktree itself so cwd/.git is a real
# DIRECTORY (not a gitlink FILE), forging git-dir==common the same way. The
# structural anchor must catch this variant too — a cwd/.git-is-a-file gate would
# have missed it.
test_gitlink_initdir_variant_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 509; then
        skip_test "gitlink fixture unavailable"
        return 0
    fi
    command rm -rf "$GL_WT/.git" 2>/dev/null || true
    git_clean -C "$GL_WT" init -q 2>/dev/null || {
        skip_test "could not re-init worktree as a standalone repo"
        return 0
    }
    local gd cm
    gd="$(git_clean -C "$GL_WT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    cm="$(git_clean -C "$GL_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$gd" ] || [ "$gd" != "$cm" ]; then
        skip_test "git init did not forge the identity in this git version"
        return 0
    fi
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "git-init-the-worktree (cwd/.git is a real DIR) disguise still DENIED"
}
# The ancestor walk / longest-prefix enclosure logic exists to handle a cwd nested
# BELOW the worktree root, not just the root itself. Drive it: poison, then invoke
# the guard with cwd at a nested subdir, and confirm a leak is still DENIED and the
# worktree's own nested path still ALLOWED.
test_gitlink_poison_nested_cwd_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 510 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    local nested="$GL_WT/pkg/sub"
    command mkdir -p "$nested" 2>/dev/null || true
    nested="$(cd "$nested" && pwd)"
    run_guard "$nested" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "poisoned session run from a nested cwd still DENIES a main leak (ancestor walk)"
    run_guard "$nested" "Edit" "file_path" "$nested/x.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "poisoned session's own nested path still allowed"
}
test_gitlink_poison_allows_own_worktree() {
    jq_required || return 0
    if ! _gitlink_fixture 516 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    run_guard "$GL_WT" "Edit" "file_path" "$GL_WT/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "poisoned worktree's own path still allowed (no over-block)"
}
# Compounding vector 1 (Bypass 1): the external worktree registry
# <main>/.git/worktrees/<id>/ is deletable with an unguarded Bash `rm` from the
# golem main loop. Deleting it must NOT reopen the hole — the enclosing-primary
# anchor does not depend on that registry.
test_gitlink_poison_plus_registry_delete_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 526 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    command rm -rf "$GL_MAIN/.git/worktrees/issue-526" 2>/dev/null || true
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "gitlink poison + registry delete still DENIES (anchor is the enclosing primary, not the registry)"
}
# Compounding vector 2 (Bypass 2): a nearer decoy `git init`ed at the writable
# ancestor <main>/.worktrees must NOT shrink main_root — the OUTERMOST enclosing
# primary (the real main) still wins, so a leak into <main>/seed.txt stays DENIED.
test_gitlink_poison_nearer_decoy_denies() {
    jq_required || return 0
    if ! _gitlink_fixture 536 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    git_clean -C "$GL_MAIN/.worktrees" init -q 2>/dev/null || true
    git_clean -C "$GL_MAIN/.worktrees" config user.email "test@example.com" 2>/dev/null || true
    git_clean -C "$GL_MAIN/.worktrees" config user.name "Test" 2>/dev/null || true
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "nearer-ancestor decoy does NOT shrink main_root (outermost primary wins, leak DENIED)"
}
# FIX B: the disarming write to the gitlink itself is denied outright, before the
# worktree-first allow that would otherwise permit an in-worktree path.
test_gitlink_write_denied() {
    jq_required || return 0
    if ! _gitlink_fixture 546; then
        skip_test "gitlink fixture unavailable"
        return 0
    fi
    run_guard "$GL_WT" "Write" "file_path" "$GL_WT/.git"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "a write to \$WT/.git (the disarm vector) is DENIED"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    assert_contains "$reason" "gitlink" "gitlink-write deny reason names the gitlink vector"
}
# The gitlink-write deny is a STRICT string equality, so a filesystem-equivalent
# but non-canonical target (`$WT//.git`, `$WT/.git/`) must be normalized first or it
# slips past while still hitting the same inode (#506 pre-PR review, HIGH,
# dynamic-repro'd). The `//`/trailing-slash normalization collapses both to
# `$WT/.git` before the equality test.
test_gitlink_write_slash_variants_denied() {
    jq_required || return 0
    if ! _gitlink_fixture 547; then
        skip_test "gitlink fixture unavailable"
        return 0
    fi
    run_guard "$GL_WT" "Write" "file_path" "$GL_WT//.git"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "doubled-slash \$WT//.git write is DENIED (normalized before the equality test)"
    run_guard "$GL_WT" "Write" "file_path" "$GL_WT/.git/"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "trailing-slash \$WT/.git/ write is DENIED (normalized)"
}
# False-positive guard: a genuine separate-git-dir main (cwd/.git is also a FILE
# with git-dir == common-dir, like the poisoned worktree) must NOT be misdetected
# as a disguised worktree — no enclosing primary owns it, so it stays ALLOWED.
test_gitlink_sgd_main_not_misdetected() {
    jq_required || return 0
    if ! _exotic_sgd_fixture 51; then
        skip_test "separate-git-dir fixture unavailable in this environment"
        return 0
    fi
    run_guard "$EX_MAIN" "Edit" "file_path" "$EX_MAIN/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "genuine separate-git-dir main edits own tree allowed (not misdetected as disguised worktree)"
}
# No-jq variants: the pure-bash fallback must still deny the poisoned leak and the
# disarming write.
test_gitlink_nojq_denies_leak() {
    if ! _gitlink_fixture 556 || ! _gitlink_poison; then
        skip_test "gitlink fixture/poison unavailable"
        return 0
    fi
    run_guard "$GL_WT" "Edit" "file_path" "$GL_MAIN/seed.txt" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' "no-jq path still denies a gitlink-poisoned leak"
}
test_gitlink_nojq_denies_write() {
    if ! _gitlink_fixture 566; then
        skip_test "gitlink fixture unavailable"
        return 0
    fi
    run_guard "$GL_WT" "Write" "file_path" "$GL_WT/.git" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' "no-jq path still denies the disarming gitlink write"
}
