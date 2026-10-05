# shellcheck shell=bash
# worktree-rm.sh — removal of the per-worktree cargo target dir (issue #1117).
#
# worktree-new.sh seeds `CARGO_TARGET_DIR=<GOLEM_CARGO_CACHE_DIR>/<repo-key>/issue-N`
# (#944; repo-keyed since #1117) and worktree-rm.sh removes it on teardown
# through remove_cache_entry — the SAME cache-entry.sh body that removes the uv
# venv (#1091/#1113/#1115). That body's every guard is pinned once, through the
# uv label, in 26-worktree-uv-venv.sh, 27-cache-entry.sh and
# 28-uv-foreign-owner.sh. This area pins what is NEW: that the cargo call site
# exists, sits after every refusal, is keyed by repo, and passes a cache root
# whose refusals are announced under the cargo label.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts and
# sources tests/lib/golem-sandbox.sh BEFORE this file — and AFTER
# 27-cache-entry.sh, whose _make_foreign the ownership case reuses. That library pins
# GOLEM_CARGO_CACHE_DIR at a nonexistent sandbox path; these tests pass their own.

# --- helpers (used only by this area, so they stay here) --------------------

# _crg_run <script> <sandbox> <cargo-cache> <issue-N> [extra-env...]
# Run worktree-new.sh or worktree-rm.sh from the sandbox with the cargo cache
# set by the caller and the uv cache pointed at a nonexistent path, so only the
# cargo arm can act. BASH_ENV is unset so an image profile cannot rewrite a PATH
# a caller passes as extra env. Captures combined output in RUN_OUT / RUN_RC.
_crg_run() {
    local script="$1" dir="$2" cache="$3" n="$4"
    shift 4
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES=".claude/settings.local.json" \
            GOLEM_CARGO_CACHE_DIR="$cache" \
            GOLEM_UV_CACHE_DIR="$dir/no-uv-cache" \
            "$@" \
            "$REAL_BASH" "$script" "$n" 2>&1)" || RUN_RC=$?
}

# _crg_entry <sandbox> <cache> <issue-N> — <cache>/<golem_repo_key>/issue-N,
# computed by CALLING config.sh's function so the tests cannot drift from it.
_crg_entry() {
    local key
    key="$(
        # shellcheck source=/dev/null
        . "$SCRIPTS/config.sh"
        golem_repo_key "$1"
    )"
    command printf '%s/%s/issue-%s\n' "$2" "$key" "$3"
}

# _crg_ignore <sandbox> — commit the TRACKED .gitignore real repos carry for the
# settings file; without it the seed refuses (it would dirty the worktree).
_crg_ignore() {
    command printf '.claude/settings.local.json\n.worktrees/\n' >"$1/.gitignore"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$1" add .gitignore 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$1" -c commit.gpgsign=false commit -qm gitignore 2>/dev/null
}

# _crg_populate <entry> — what `cargo build` leaves: nested incremental objects.
_crg_populate() {
    command mkdir -p "$1/debug/incremental/crate-abc"
    command printf 'o\n' >"$1/debug/incremental/crate-abc/x.o"
}

# --- tests ------------------------------------------------------------------

# AC1 end-to-end: create → seed lands at the repo-keyed path → target populated
# → teardown removes it. Sibling issues and the cache root survive, and the seed
# left the worktree CLEAN so teardown was not refused.
test_worktree_rm_removes_cargo_target_dir() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _crg_ignore "$sb"
    local cache="$sb/targets" entry sibling
    command mkdir -p "$cache"
    entry="$(_crg_entry "$sb" "$cache" 61)"
    sibling="$(_crg_entry "$sb" "$cache" 62)"
    _crg_populate "$sibling"

    _crg_run "$WT_NEW" "$sb" "$cache" 61
    local seeded
    seeded="$(command jq -r '.env.CARGO_TARGET_DIR // empty' \
        "$sb/.worktrees/issue-61/.claude/settings.local.json" 2>/dev/null)"
    assert_equals "$entry" "$seeded" \
        "the seed landed at the repo-keyed path (guards a vacuous teardown pass)"
    _crg_populate "$entry"

    _crg_run "$WT_RM" "$sb" "$cache" 61
    assert_exit 0 "$RUN_RC" "teardown succeeds after the cargo seed — no dirty refusal"
    assert_contains "$RUN_OUT" "removed cargo target dir $entry" "reports the removal"
    assert_true "[ ! -e \"$entry\" ]" "The per-issue target dir is gone"
    assert_true "[ -f \"$sibling/debug/incremental/crate-abc/x.o\" ]" \
        "A sibling issue's target dir is untouched"
    assert_true "[ -d \"$cache\" ]" "The cache root itself is untouched"
}

# AC2: the removal sits AFTER every refusal, so a worktree holding uncommitted
# work keeps its target dir with it.
test_worktree_rm_dirty_refusal_keeps_cargo_target_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 63)"
    _crg_run "$WT_NEW" "$sb" "$cache" 63
    _crg_populate "$entry"
    command printf 'wip\n' >"$sb/.worktrees/issue-63/seed.txt"

    _crg_run "$WT_RM" "$sb" "$cache" 63
    assert_exit 1 "$RUN_RC" "worktree-rm refuses the dirty worktree"
    assert_true "[ -d \"$entry/debug\" ]" "The refused worktree's target dir survives"
    assert_not_contains "$RUN_OUT" "cargo target dir" "reports no removal on refusal"
}

# AC3, and the keying decision it forced: the cache is one mount shared by every
# repo in the container and issue numbers are per-repo, so two repos' "issue 42"
# must get two target dirs — and tearing one down must not delete the other.
# Keyed by issue alone (the pre-#1117 seed), this test fails at the inequality.
test_worktree_rm_spares_another_repos_same_issue_cargo_target() {
    local a b
    new_sandbox a
    new_sandbox b
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _crg_ignore "$a"
    _crg_ignore "$b"
    local cache="$WORKDIR/shared-targets-$$"
    command mkdir -p "$cache"

    _crg_run "$WT_NEW" "$a" "$cache" 42
    _crg_run "$WT_NEW" "$b" "$cache" 42
    local ta tb
    ta="$(command jq -r '.env.CARGO_TARGET_DIR // empty' \
        "$a/.worktrees/issue-42/.claude/settings.local.json" 2>/dev/null)"
    tb="$(command jq -r '.env.CARGO_TARGET_DIR // empty' \
        "$b/.worktrees/issue-42/.claude/settings.local.json" 2>/dev/null)"
    assert_not_empty "$ta" "repo A seeded (guards a vacuous pass)"
    assert_not_empty "$tb" "repo B seeded (guards a vacuous pass)"
    assert_true "[ \"$ta\" != \"$tb\" ]" \
        "The same issue number in two repos gets two DIFFERENT target dirs"
    _crg_populate "$tb"

    _crg_run "$WT_RM" "$a" "$cache" 42
    assert_exit 0 "$RUN_RC" "repo A's teardown exits 0"
    assert_true "[ ! -e \"$ta\" ]" "repo A's target dir is removed"
    assert_true "[ -f \"$tb/debug/incremental/crate-abc/x.o\" ]" \
        "repo B's target dir for the SAME issue number survives"
    command rm -rf "$cache"
}

# A pre-#1117 un-namespaced <cache>/issue-N cannot be attributed to a repo, so
# teardown never touches it — even while it removes this repo's keyed entry.
test_worktree_rm_leaves_legacy_unkeyed_cargo_target() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 64)"
    _crg_run "$WT_NEW" "$sb" "$cache" 64
    _crg_populate "$entry"
    _crg_populate "$cache/issue-64"

    _crg_run "$WT_RM" "$sb" "$cache" 64
    assert_exit 0 "$RUN_RC" "teardown exits 0"
    assert_true "[ ! -e \"$entry\" ]" "the keyed entry is removed (guards a vacuous pass)"
    assert_true "[ -f \"$cache/issue-64/debug/incremental/crate-abc/x.o\" ]" \
        "the legacy un-namespaced target dir is left alone"
}

# AC4: a symlinked leaf is refused, announced under the cargo label, exit 0.
test_worktree_rm_refuses_symlinked_cargo_target_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 65)"
    command mkdir -p "$sb/precious" "${entry%/*}"
    command printf 'keep\n' >"$sb/precious/file"
    command ln -s "$sb/precious" "$entry"
    _crg_run "$WT_NEW" "$sb" "$cache" 65

    _crg_run "$WT_RM" "$sb" "$cache" 65
    assert_exit 0 "$RUN_RC" "teardown exits 0 with a symlinked target dir"
    assert_not_contains "$RUN_OUT" "removed cargo target dir" "does not remove a symlinked leaf"
    assert_contains "$RUN_OUT" "refusing to remove cargo target dir $entry" \
        "says it refused — a silent skip would read as 'nothing to remove'"
    assert_true "[ -f \"$sb/precious/file\" ]" "The symlink target's content survives"
}

# AC4: a planted `<cache>/<repo-key> -> elsewhere` must not let teardown delete
# `elsewhere/issue-N`. The leaf resolves as a real dir, so only the parent check
# can refuse.
test_worktree_rm_refuses_symlinked_cargo_repo_key_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 66)"
    command mkdir -p "$cache" "$sb/elsewhere/issue-66"
    command printf 'keep\n' >"$sb/elsewhere/issue-66/file"
    command ln -s "$sb/elsewhere" "${entry%/*}"
    assert_true "[ -d \"$entry\" ] && [ ! -L \"$entry\" ]" \
        "fixture: the LEAF resolves as a real dir, so only a parent check can refuse"
    _crg_run "$WT_NEW" "$sb" "$cache" 66

    _crg_run "$WT_RM" "$sb" "$cache" 66
    assert_exit 0 "$RUN_RC" "teardown exits 0 with a symlinked repo-key dir"
    assert_contains "$RUN_OUT" "refusing to remove cargo target dir $entry" \
        "the parent check was REACHED and refused (guards a vacuous pass)"
    assert_true "[ -f \"$sb/elsewhere/issue-66/file\" ]" \
        "The link target's issue dir survives"
}

# AC4: a removal that fails warns and still exits 0. A read-only <repo-key>
# parent makes the final rmdir fail; root defeats that, so skip rather than
# assert a false pass.
test_worktree_rm_failed_cargo_removal_warns_and_exits_0() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 67)"
    _crg_run "$WT_NEW" "$sb" "$cache" 67
    _crg_populate "$entry"
    command chmod 555 "${entry%/*}" 2>/dev/null || true
    if [ -w "${entry%/*}" ]; then
        command chmod 755 "${entry%/*}" 2>/dev/null || true
        skip_test "target parent still writable after chmod 555 (running as root?)"
        return
    fi

    _crg_run "$WT_RM" "$sb" "$cache" 67
    local rc="$RUN_RC" out="$RUN_OUT"
    command chmod 755 "${entry%/*}" 2>/dev/null || true
    assert_exit 0 "$rc" "teardown still exits 0 when the target dir cannot be removed"
    assert_contains "$out" "could not remove cargo target dir $entry" "warns, naming the dir"
    assert_not_contains "$out" "removed cargo target dir" "does not claim a removal that failed"
    assert_contains "$out" "removed worktree" "the worktree teardown itself still happened"
}

# AC5: with no cache dir at all, teardown is a silent no-op for cargo.
test_worktree_rm_absent_cargo_cache_is_noop() {
    local sb
    new_sandbox sb
    local cache="$sb/no-such-targets"
    _crg_run "$WT_NEW" "$sb" "$cache" 68
    _crg_run "$WT_RM" "$sb" "$cache" 68
    assert_exit 0 "$RUN_RC" "teardown exits 0 with the cargo cache absent"
    assert_contains "$RUN_OUT" "removed worktree" "the teardown itself ran (guards a vacuous pass)"
    assert_not_contains "$RUN_OUT" "cargo target dir" "says nothing about a cache that does not exist"
    assert_true "[ ! -e \"$cache\" ]" "teardown does not create the cache location"
}

# Name mode never had a cargo seed (keyed by issue number only), so a name-mode
# teardown must not reach into the cache, even past a colliding-looking name.
test_worktree_rm_name_mode_leaves_cargo_cache_alone() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" key_dir
    key_dir="$(_crg_entry "$sb" "$cache" scratch)"
    key_dir="${key_dir%/*}"
    command mkdir -p "$key_dir/issue-scratch" "$key_dir/scratch"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q .worktrees/scratch -b scratch 2>/dev/null

    _crg_run "$WT_RM" "$sb" "$cache" scratch
    assert_exit 0 "$RUN_RC" "name-mode teardown exits 0"
    assert_true "[ ! -e \"$sb/.worktrees/scratch\" ]" \
        "the named worktree was removed (guards a vacuous pass)"
    assert_true "[ -d \"$key_dir/issue-scratch\" ] && [ -d \"$key_dir/scratch\" ]" \
        "name mode touches nothing under the cargo cache"
}

# With no repo key there is no path to verify, so teardown neither guesses one
# (an empty key would aim the delete at <cache>//issue-N, or at the legacy
# un-namespaced dir) nor skips in silence: the warning names the cargo label.
# A PATH stub fails only cksum; its marker attributes the skip to the key.
test_worktree_rm_failed_repo_key_warns_and_keeps_cargo_target() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 69)"
    _crg_run "$WT_NEW" "$sb" "$cache" 69
    _crg_populate "$entry"
    _crg_populate "$cache/issue-69"
    command mkdir -p "$sb/stubbin"
    command printf '#!/usr/bin/env bash\n: >"%s/cksum-ran"\nexit 1\n' "$sb" \
        >"$sb/stubbin/cksum"
    command chmod +x "$sb/stubbin/cksum"

    _crg_run "$WT_RM" "$sb" "$cache" 69 PATH="$sb/stubbin:$PATH"
    assert_exit 0 "$RUN_RC" "teardown exits 0 when the repo key cannot be computed"
    assert_file_exists "$sb/cksum-ran" "the failing cksum stub was actually invoked"
    assert_contains "$RUN_OUT" "any cargo target dir for issue 69 under $cache was left in place" \
        "the skip is announced under the cargo label"
    assert_true "[ -d \"$entry/debug\" ]" "The keyed target dir survives"
    assert_true "[ -d \"$cache/issue-69/debug\" ]" \
        "The un-namespaced <cache>/issue-N is NOT deleted"
}

# The ownership refusal (cache_entry_remove rc 3) through the cargo call site:
# our issue-N under a foreign-owned <repo-key> dir is kept and the refusal names
# ownership. Needs root or passwordless sudo to build; skips otherwise.
test_worktree_rm_refuses_foreign_owned_cargo_repo_key_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/targets" entry
    entry="$(_crg_entry "$sb" "$cache" 70)"
    _crg_run "$WT_NEW" "$sb" "$cache" 70
    _crg_populate "$entry"
    _make_foreign "${entry%/*}" || return 0

    _crg_run "$WT_RM" "$sb" "$cache" 70
    assert_exit 0 "$RUN_RC" "teardown exits 0 under a foreign-owned repo-key dir"
    assert_contains "$RUN_OUT" "refusing to remove cargo target dir $entry" \
        "the refusal is announced under the cargo label"
    assert_contains "$RUN_OUT" "not owned by you" "...and names ownership as the reason"
    assert_true "[ -f \"$entry/debug/incremental/crate-abc/x.o\" ]" \
        "the target dir under the foreign parent survives"
}

# ORDERING: the cache entries are removed AFTER the golem's tmux session is
# killed (#1117 review c2). The session runs with the seeded CARGO_TARGET_DIR,
# so a cargo build still alive in it would race the delete and could recreate
# the dir behind it — leaking the entry for good. A live session cannot be
# driven from this suite, so the order is pinned on the source: EVERY
# remove_cache_entry call (any indentation, comment lines excluded) must follow
# the kill-session line. The earliest call is the one compared — it bounds them
# all — and the call count is pinned at 2 (uv + cargo), so a call that stops
# matching the pattern, or a third added above the kill, fails loud rather than
# slipping out of the comparison. Both anchors are asserted non-empty.
test_worktree_rm_removes_cache_entries_after_tmux_kill() {
    local kill_ln calls rm_ln n
    kill_ln="$(command grep -n 'tmux kill-session -t' "$WT_RM" | command sed -n '1s/:.*//p')"
    calls="$(command grep -n 'remove_cache_entry "' "$WT_RM" |
        command grep -v '^[0-9]*:[[:space:]]*#')"
    rm_ln="$(command printf '%s\n' "$calls" | command sed -n '1s/:.*//p')"
    n="$(command printf '%s\n' "$calls" | command grep -c 'remove_cache_entry')"
    assert_not_empty "$kill_ln" "found the tmux kill-session call (guards a vacuous pass)"
    assert_not_empty "$rm_ln" "found the remove_cache_entry calls (guards a vacuous pass)"
    assert_equals "2" "$n" "exactly two cache-entry teardown calls: uv venv and cargo target dir"
    assert_true "[ \"${rm_ln:-0}\" -gt \"${kill_ln:-0}\" ]" \
        "every cache entry is removed after the tmux session is killed"
}
