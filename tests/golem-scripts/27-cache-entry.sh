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

# _ce_fn <fn> <args...> — run any cache-entry.sh function in a subshell; the
# status lands in CE_RC, combined output in CE_OUT.
_ce_fn() {
    CE_RC=0
    CE_OUT="$(
        # shellcheck source=/dev/null
        . "$CACHE_ENTRY"
        "$@" 2>&1
    )" || CE_RC=$?
}

# _make_foreign <dir> — hand <dir> to another uid (nobody, 65534) so the
# ownership refusal (#1115) has something to refuse. Also used by
# 28-uv-foreign-owner.sh, sourced after this file. Mode 0777 FIRST, so the
# sandbox cleanup — running as us — can still empty and unlink it. Needs root
# or passwordless sudo; otherwise skips (AC3): a non-root runner cannot create a
# foreign-owned fixture, and faking one would test nothing.
_make_foreign() {
    command chmod 0777 "$1" 2>/dev/null || return 1
    if [ "$(command id -u)" = 0 ]; then
        command chown 65534 "$1" 2>/dev/null
    else
        command sudo -n chown 65534 "$1" 2>/dev/null
    fi
    if [ -O "$1" ]; then
        skip_test "cannot create a foreign-owned fixture (not root, no passwordless sudo)"
        return 1
    fi
    return 0
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

# The `!= "/"` guard is reachable only in the KEYLESS (cargo) shape: with a
# <sub>, a `//` root is already refused by the parent comparison (`/key` never
# equals `//key`), so a keyed row stays green with the guard deleted. Keyless,
# the parent IS the root and the comparison accepts — only the guard refuses
# seeding `/issue-N`. Measured: removing the guard flips both rows below to 0.
test_cache_entry_path_refuses_a_root_that_is_slash() {
    _ce "//" "" 7
    assert_equals 1 "$CE_RC" "a keyless '//' root (canonically '/') is refused"
    _ce "/." "" 7
    assert_equals 1 "$CE_RC" "a keyless '/.' root (canonically '/') is refused"
}

# The check verifies only the PARENT, so a traversing <N> with an existing
# issue-7 would otherwise verify and print a path resolving to the cache ROOT —
# the very thing a caller then `rm -rf`s. Measured before the digit guard:
# `7/../..` returned 0.
test_cache_entry_path_refuses_a_non_numeric_issue() {
    local sb n
    new_sandbox sb
    command mkdir -p "$sb/cache/key/issue-7"
    for n in '7/../..' '7/..' 'x' ''; do
        _ce "$sb/cache" key "$n"
        assert_equals 1 "$CE_RC" "issue number '$n' is refused — digits only"
    done
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

# cache_entry_owned (#1115): a path that exists but belongs to another uid is
# refused. Non-root runners cannot chown a fixture, so the foreign rows use
# directories root already owns: /usr/lib as a foreign LEAF, and /tmp as the
# foreign PARENT of a leaf we create there. The foreign rows skip when the
# runner IS uid 0, because then those directories are genuinely ours.
test_cache_entry_owned_refuses_a_foreign_owner() {
    local sb leaf
    new_sandbox sb
    command mkdir -p "$sb/cache/key/issue-7"
    _ce_fn cache_entry_owned "$sb/cache/key/issue-7" key
    assert_equals 0 "$CE_RC" "our own leaf under our own key verifies — positive control"
    _ce_fn cache_entry_owned "$sb/cache/key/issue-8" key
    assert_equals 1 "$CE_RC" "a missing leaf has no owner, so it is refused"
    if [ "$(command id -u)" = 0 ]; then
        skip_test "running as root — /usr/lib and /tmp are ours, no foreign fixture"
        return 0
    fi
    _ce_fn cache_entry_owned /usr/lib ""
    assert_equals 1 "$CE_RC" "a leaf owned by another uid (root's /usr/lib) is refused"
    if [ -O /tmp ]; then
        skip_test "/tmp is owned by this runner — no foreign parent available"
        return 0
    fi
    leaf="$(command mktemp -d /tmp/ce-owned.XXXXXX)" || return 1
    _ce_fn cache_entry_owned "$leaf" key
    assert_equals 1 "$CE_RC" "our leaf under a FOREIGN <key> parent is refused"
    _ce_fn cache_entry_owned "$leaf" ""
    assert_equals 0 "$CE_RC" \
        "keyless (cargo shape) the parent is the operator's cache root — not checked"
    command rmdir "$leaf"
}

# cache_entry_remove deletes RELATIVE to a directory it has entered and
# re-verified with `pwd -P` (#1115) — the remedy for a <key> swapped for a link
# between cache_entry_path's check and the delete. The swap itself cannot be
# raced deterministically, so these rows hand it a path that is ALREADY a link,
# which is exactly what the swap leaves behind: the `pwd -P` re-check is the only
# thing that can refuse it (cache_entry_path is not called here).
test_cache_entry_remove_deletes_a_verified_entry() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/cache/key/issue-7/bin/.hidden"
    command printf 'x\n' >"$sb/cache/key/issue-7/bin/.hidden/f"
    command ln -s /nonexistent "$sb/cache/key/issue-7/dangling"
    local real
    real="$(command readlink -f "$sb/cache/key")"
    _ce_fn cache_entry_remove "$sb/cache/key" "$real" key 7
    assert_equals 0 "$CE_RC" "a verified, owned entry is removed — positive control"
    assert_true "[ ! -e \"$sb/cache/key/issue-7\" ] && [ ! -L \"$sb/cache/key/issue-7\" ]" \
        "the entry, dotfiles and a dangling link inside it are all gone"
    assert_true "[ -d \"$sb/cache/key\" ]" "the <key> parent survives"
}

test_cache_entry_remove_refuses_a_parent_that_is_not_where_expected() {
    local sb real
    new_sandbox sb
    command mkdir -p "$sb/cache/key" "$sb/elsewhere/issue-7"
    command printf 'keep\n' >"$sb/elsewhere/issue-7/file"
    real="$(command readlink -f "$sb/cache")/key"
    command rmdir "$sb/cache/key"
    command ln -s "$sb/elsewhere" "$sb/cache/key"
    _ce_fn cache_entry_remove "$sb/cache/key" "$real" key 7
    assert_equals 2 "$CE_RC" "a <key> that became a link is refused by the pwd -P re-check"
    assert_true "[ -f \"$sb/elsewhere/issue-7/file\" ]" "the link target's issue dir survives"
}

test_cache_entry_remove_refuses_a_leaf_that_is_a_link() {
    local sb real
    new_sandbox sb
    command mkdir -p "$sb/cache/key" "$sb/elsewhere"
    command printf 'keep\n' >"$sb/elsewhere/file"
    command ln -s "$sb/elsewhere" "$sb/cache/key/issue-7"
    real="$(command readlink -f "$sb/cache/key")"
    _ce_fn cache_entry_remove "$sb/cache/key" "$real" key 7
    assert_equals 2 "$CE_RC" "an issue-N that became a link is refused"
    assert_true "[ -f \"$sb/elsewhere/file\" ]" "the link target's content survives"
    assert_true "[ -L \"$sb/cache/key/issue-7\" ]" "the link itself is left in place"
}

# Teardown's own ownership check on the keyed PARENT, run on `.` from inside the
# re-verified directory: /tmp is root's, the issue-N we create there is ours.
# Keyless, the parent is the operator's cache root and is not checked.
test_cache_entry_remove_refuses_a_foreign_owned_parent() {
    local leaf n tmp_real
    if [ "$(command id -u)" = 0 ] || [ -O /tmp ]; then
        skip_test "/tmp is owned by this runner — no foreign parent available"
        return 0
    fi
    tmp_real="$(command readlink -f /tmp)"
    n="$$${RANDOM}"
    leaf="/tmp/issue-$n"
    command mkdir "$leaf" || return 1
    _ce_fn cache_entry_remove /tmp "$tmp_real" key "$n"
    assert_equals 3 "$CE_RC" "a keyed parent owned by another uid is refused as not-ours"
    assert_true "[ -d \"$leaf\" ]" "nothing was deleted under the foreign parent"
    _ce_fn cache_entry_remove /tmp "$tmp_real" "" "$n"
    assert_equals 0 "$CE_RC" "keyless, the root-owned cache root is not an ownership refusal"
    assert_true "[ ! -e \"$leaf\" ]" "...and our own leaf under it is removed"
    command rmdir "$leaf" 2>/dev/null || true
}

# The LEAF ownership guard, run on `.` from inside the re-verified issue-N: a
# foreign-owned issue-N under OUR <key> dir is refused and its content kept.
# Only chown can build this fixture, so it skips without root/sudo (AC3).
test_cache_entry_remove_refuses_a_foreign_owned_leaf() {
    local sb real
    new_sandbox sb
    command mkdir -p "$sb/cache/key/issue-7"
    command printf 'theirs\n' >"$sb/cache/key/issue-7/marker"
    _make_foreign "$sb/cache/key/issue-7" || return 0
    real="$(command readlink -f "$sb/cache/key")"
    _ce_fn cache_entry_remove "$sb/cache/key" "$real" key 7
    assert_equals 3 "$CE_RC" "a foreign-owned issue-N is refused as not-ours"
    assert_true "[ -f \"$sb/cache/key/issue-7/marker\" ]" "its content survives"
}

# Patterns are `$`-free on purpose: assert_file_contains is a BRE grep, where a
# `$` inside the pattern never matches a literal `$` — a negative assertion
# spelled `readlink -f "$parent"` matched neither the old code nor the new and
# so could never fail. Each pattern below was checked against both trees: the
# positives are absent before this change, the negatives present before it.
test_cache_entry_path_is_the_one_derivation() {
    assert_file_contains "$WT_NEW" 'cache_entry_path "' \
        "worktree-new.sh's seed derives its target through cache_entry_path"
    assert_file_contains "$CACHE_ENTRY" 'cache_entry_path "' \
        "remove_uv_venv derives its target through cache_entry_path"
    assert_file_contains "$WT_RM" 'remove_uv_venv "' \
        "worktree-rm.sh tears the venv down through remove_uv_venv"
    assert_file_not_contains "$WT_RM" 'uv_root_real' \
        "worktree-rm.sh keeps no inline copy of the path verification"
    assert_file_not_contains "$WT_NEW" 'parent_real' \
        "worktree-new.sh keeps no inline copy of the path verification"
    assert_file_contains "$WT_NEW" 'cache_entry_owned "' \
        "worktree-new.sh's seed checks ownership through cache_entry_owned (#1115)"
    assert_file_contains "$CACHE_ENTRY" 'cache_entry_remove "' \
        "remove_uv_venv deletes through cache_entry_remove (#1115)"
    assert_file_not_contains "$CACHE_ENTRY" 'command rm -rf' \
        "cache-entry.sh deletes nothing by name with rm -rf (#1115)"
}
