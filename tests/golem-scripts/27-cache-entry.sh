# shellcheck shell=bash
# cache-entry.sh — the ONE derive-and-verify function for a per-issue cache
# entry, shared by worktree-new.sh's seed and worktree-rm.sh's uv teardown
# (issue #1113).
#
# 26-worktree-uv-venv.sh pins both sides end-to-end through the scripts. This
# area pins the shared function directly, row by row, and that both scripts
# actually route through it — the AC is "one function, both call it", and a
# copy re-inlined into either script would pass every end-to-end case.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts and
# sources tests/lib/golem-sandbox.sh BEFORE this file.

# --- helpers (used only by this area, so they stay here) --------------------

# _ce <root> <sub> <N> — run cache_entry_path in a subshell; the printed path
# lands in CE_OUT, the status in CE_RC.
_ce() {
    CE_RC=0
    CE_OUT="$(
        # shellcheck source=/dev/null
        . "$CACHE_ENTRY"
        cache_entry_path "$@"
    )" || CE_RC=$?
}

# --- tests ------------------------------------------------------------------

test_cache_entry_path_accepts_plain_and_keyless_paths() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/cache/key"
    _ce "$sb/cache" key 7
    assert_equals 0 "$CE_RC" "a plain <cache>/<key>/issue-N verifies"
    assert_equals "$sb/cache/key/issue-7" "$CE_OUT" "the path is <cache>/<key>/issue-N"
    _ce "$sb/cache/" "" 7
    assert_equals 0 "$CE_RC" "an empty sub (the cargo shape) verifies against the root"
    assert_equals "$sb/cache/issue-7" "$CE_OUT" \
        "a trailing '/' on the root is dropped — seed and teardown name one path"
}

test_cache_entry_path_refuses_symlinks_below_the_root() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/cache" "$sb/elsewhere/issue-7" "$sb/cache/real"
    command ln -s "$sb/elsewhere" "$sb/cache/key"
    _ce "$sb/cache" key 7
    assert_equals 1 "$CE_RC" "a symlinked <key> parent is refused"
    assert_equals "$sb/cache/key/issue-7" "$CE_OUT" \
        "a refused path is still printed, so the caller can name it"
    command ln -s "$sb/elsewhere/issue-7" "$sb/cache/real/issue-7"
    _ce "$sb/cache" real 7
    assert_equals 1 "$CE_RC" "a symlinked issue-N leaf is refused"
}

test_cache_entry_path_follows_a_symlinked_root() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/disk/key"
    command ln -s "$sb/disk" "$sb/cache"
    _ce "$sb/cache" key 7
    assert_equals 0 "$CE_RC" \
        "the ROOT itself may be a symlink — positive control for the refusals"
}

test_cache_entry_path_refuses_a_root_that_is_slash() {
    _ce "//" key 7
    assert_equals 1 "$CE_RC" "a root canonicalizing to '/' is refused"
}

# A cache root that does not exist leaves nothing to canonicalize the parent
# against, so the entry is unverifiable and refused. (A missing <key> parent
# under an EXISTING root is deliberately not pinned: GNU `readlink -f` resolves
# a missing last component, so it verifies — harmless, since the seed creates
# that parent before calling and teardown finds no venv to delete.)
test_cache_entry_path_refuses_unverifiable_paths() {
    local sb
    new_sandbox sb
    _ce "$sb/no-such-cache" key 7
    assert_equals 1 "$CE_RC" "a cache root that does not exist is refused"
}

test_cache_entry_path_is_the_one_derivation() {
    assert_file_contains "$WT_NEW" 'cache_entry_path "$cache_root"' \
        "worktree-new.sh's seed derives its target through cache_entry_path"
    assert_file_contains "$CACHE_ENTRY" 'cache_entry_path "$cache"' \
        "remove_uv_venv derives its target through cache_entry_path"
    assert_file_contains "$WT_RM" 'remove_uv_venv "$GOLEM_UV_CACHE_DIR"' \
        "worktree-rm.sh tears the venv down through remove_uv_venv"
    assert_file_not_contains "$WT_RM" 'readlink -f "$GOLEM_UV_CACHE_DIR"' \
        "worktree-rm.sh keeps no inline copy of the path verification"
    assert_file_not_contains "$WT_NEW" 'parent_real=' \
        "worktree-new.sh keeps no inline copy of the path verification"
}
