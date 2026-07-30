# shellcheck shell=bash
# Config poisoning — worktree-scope guard tests (issue #564 split).
#
# Covers the guard's trust anchor being non-poisonable (#501) — including a stray core.bare on a real working checkout, which must NOT silence a leak.
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

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
