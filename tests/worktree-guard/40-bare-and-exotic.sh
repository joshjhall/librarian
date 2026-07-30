# shellcheck shell=bash
# Bare-repo and separate-git-dir topologies — worktree-scope guard tests (issue #564 split).
#
# Covers the bare-repo worktree host (#501) and the exotic `gitdir:` cross-tree case, which must fail open LOUDLY and stay immune to core.bare poisoning (#501 cycle-2 CRITICAL).
#
# Sourced by tests/validate-worktree-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/worktree-guard-fixtures.sh (building the shared repo
# topologies) BEFORE this file. This fragment only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.

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
