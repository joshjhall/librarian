# shellcheck shell=bash
# worktree-new.sh / worktree-rm.sh — a uv cache entry owned by ANOTHER uid is
# neither seeded into nor deleted (issue #1115).
#
# On a cache root shared with a co-tenant, the predictable
# `<cache>/<repo-key>/issue-N` can be pre-created by someone else with no
# symlink at all. These rows drive both scripts end-to-end against such an
# entry. 27-cache-entry.sh pins the shared functions directly, row by row.
#
# A foreign-owned fixture needs root or passwordless sudo; without either, each
# row SKIPS rather than passing (#1115 AC3).
#
# Sourced by tests/validate-golem-scripts.sh AFTER 26-worktree-uv-venv.sh and
# 27-cache-entry.sh: it reuses 26's _uv_* run/fixture helpers and 27's
# _make_foreign rather than copying them.

# --- tests ------------------------------------------------------------------

# AC1+AC2 (#1115), seed side: a co-tenant on a shared cache pre-creates the
# predictable issue-N with no symlink at all. It is not seeded into, and the
# refusal is said on stderr. Positive control:
# test_worktree_new_uv_seeds_project_environment, the same fixture without the
# foreign owner.
test_worktree_new_uv_refuses_foreign_owned_venv() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 71)"
    command mkdir -p "$venv"
    _make_foreign "$venv" || return 0

    _uv_run "$WT_NEW" "$sb" "$cache" 71
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a foreign-owned venv dir"
    assert_contains "$RUN_OUT" "refusing to seed UV_PROJECT_ENVIRONMENT=$venv" \
        "the refusal is announced — a silent skip reads as 'not a uv project'"
    assert_equals "" "$(_uv_key_of "$sb" 71)" "writes no UV_PROJECT_ENVIRONMENT"
}

# The <repo-key> PARENT is checked too: a co-tenant owning it can swap or plant
# entries under it even when the leaf we create there is ours.
test_worktree_new_uv_refuses_foreign_owned_repo_key_dir() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 72)"
    command mkdir -p "${venv%/*}"
    _make_foreign "${venv%/*}" || return 0

    _uv_run "$WT_NEW" "$sb" "$cache" 72
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a foreign-owned repo-key dir"
    assert_contains "$RUN_OUT" "refusing to seed UV_PROJECT_ENVIRONMENT=$venv" \
        "the parent check was reached and refused out loud"
    assert_equals "" "$(_uv_key_of "$sb" 72)" "writes no UV_PROJECT_ENVIRONMENT"
}

# AC1+AC2 (#1115), teardown side: a foreign-owned issue-N is not deleted, and the
# refusal is said on stderr. Teardown still exits 0.
test_worktree_rm_refuses_foreign_owned_uv_venv() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 73)"
    _uv_run "$WT_NEW" "$sb" "$cache" 73
    command mkdir -p "$venv"
    command printf 'theirs\n' >"$venv/marker"
    _make_foreign "$venv" || return 0

    _uv_run "$WT_RM" "$sb" "$cache" 73
    assert_exit 0 "$RUN_RC" "teardown exits 0 with a foreign-owned venv"
    assert_contains "$RUN_OUT" "refusing to remove uv venv $venv" "the refusal is announced"
    assert_contains "$RUN_OUT" "not owned by you" "...and names ownership as the reason"
    assert_true "[ -f \"$venv/marker\" ]" "the foreign-owned venv's content survives"
}

# Teardown's keyed-PARENT refusal, end to end: our own issue-N under a
# foreign-owned <repo-key> dir is kept, and remove_uv_venv names ownership — the
# rc-3 mapping 27-cache-entry.sh cannot reach, since it calls the inner function.
test_worktree_rm_refuses_foreign_owned_uv_repo_key_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 74)"
    _uv_run "$WT_NEW" "$sb" "$cache" 74
    command mkdir -p "$venv"
    command printf 'ours\n' >"$venv/marker"
    _make_foreign "${venv%/*}" || return 0

    _uv_run "$WT_RM" "$sb" "$cache" 74
    assert_exit 0 "$RUN_RC" "teardown exits 0 under a foreign-owned repo-key dir"
    assert_contains "$RUN_OUT" "refusing to remove uv venv $venv" "the refusal is announced"
    assert_contains "$RUN_OUT" "not owned by you" "...and names ownership as the reason"
    assert_true "[ -f \"$venv/marker\" ]" "the venv under the foreign parent survives"
}
