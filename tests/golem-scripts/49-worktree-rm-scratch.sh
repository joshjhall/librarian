# shellcheck shell=bash
# worktree-rm.sh — removal of the issue's review scratch dirs and golem
# status/work-registry files on issue-mode teardown (issue #1166).
#
# Two per-issue artifacts used to outlive every teardown path: the review
# loop's ~/.cache/librarian-review/{golem,solo}-N/ (#1094) and the status dir's
# golem-N.json + golem-N.work.jsonl (#949). Each case below pins one acceptance
# criterion; each deletion is pinned by its own assertion so dropping its call
# in worktree-rm.sh turns exactly that assertion red.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts and
# sources tests/lib/golem-sandbox.sh BEFORE this file. run_in pins HOME at the
# sandbox, so the scratch root is <sandbox>/.cache/librarian-review.

# --- helpers (used only by this area, so they stay here) --------------------

# _scr_seed <sandbox> <N> — plant all four per-issue artifacts for issue N.
_scr_seed() {
    local sb="$1" n="$2" g
    for g in "golem-$n" "solo-$n"; do
        command mkdir -p "$sb/.cache/librarian-review/$g"
        command printf 'x\n' >"$sb/.cache/librarian-review/$g/cycle1.json"
    done
    command mkdir -p "$sb/.worktrees/.status"
    command printf '{}\n' >"$sb/.worktrees/.status/golem-$n.json"
    command printf '{}\n' >"$sb/.worktrees/.status/golem-$n.work.jsonl"
}

# _scr_exists <path> <message> / _scr_gone <path> <message> — presence of a
# path of ANY type (`-L` too, so a dangling link never reads as gone).
_scr_exists() {
    local st=gone
    if [ -e "$1" ] || [ -L "$1" ]; then st=present; fi
    assert_equals present "$st" "$2"
}
_scr_gone() {
    local st=gone
    if [ -e "$1" ] || [ -L "$1" ]; then st=present; fi
    assert_equals gone "$st" "$2"
}

# _scr_assert_present <sandbox> <N> <label> / _scr_assert_absent — one
# assertion PER artifact, so a dropped deletion names itself.
_scr_assert_present() {
    local sb="$1" n="$2" label="$3"
    _scr_exists "$sb/.cache/librarian-review/golem-$n" "$label: golem-$n scratch dir kept"
    _scr_exists "$sb/.cache/librarian-review/solo-$n" "$label: solo-$n scratch dir kept"
    assert_file_exists "$sb/.worktrees/.status/golem-$n.json" "$label: golem-$n.json kept"
    assert_file_exists "$sb/.worktrees/.status/golem-$n.work.jsonl" "$label: golem-$n.work.jsonl kept"
}
_scr_assert_absent() {
    local sb="$1" n="$2"
    _scr_gone "$sb/.cache/librarian-review/golem-$n" "golem-$n scratch dir removed"
    _scr_gone "$sb/.cache/librarian-review/solo-$n" "solo-$n scratch dir removed"
    _scr_gone "$sb/.worktrees/.status/golem-$n.json" "golem-$n.json removed"
    _scr_gone "$sb/.worktrees/.status/golem-$n.work.jsonl" "golem-$n.work.jsonl removed"
}

# --- cases ------------------------------------------------------------------

# Teardown removes all four for THIS issue, and a sibling issue's survive.
test_worktree_rm_removes_scratch_and_registry() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 71
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    _scr_seed "$sb" 71
    _scr_seed "$sb" 72
    run_in "$sb" "$WT_RM" 71
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds"
    _scr_assert_absent "$sb" 71
    assert_contains "$RUN_OUT" "removed review scratch dir" "announces the scratch removal"
    _scr_assert_present "$sb" 72 "sibling issue"
}

# The artifacts alone (worktree already gone) are still reaped, and count as a
# teardown rather than "nothing to remove".
test_worktree_rm_reaps_scratch_without_worktree() {
    local sb
    new_sandbox sb
    _scr_seed "$sb" 73
    run_in "$sb" "$WT_RM" 73
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds with only leftovers"
    _scr_assert_absent "$sb" 73
    assert_not_contains "$RUN_OUT" "nothing to remove" "leftovers count as torn down"
}

# A dirty-worktree refusal exits before the deletions: all four survive.
test_worktree_rm_dirty_refusal_keeps_scratch() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 74
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'work\n' >>"$sb/.worktrees/issue-74/seed.txt"
    _scr_seed "$sb" 74
    run_in "$sb" "$WT_RM" 74
    assert_exit 1 "$RUN_RC" "worktree-rm refuses the dirty worktree"
    _scr_assert_present "$sb" 74 "dirty refusal"
}

# Name mode never touches them — even for a name that ends in digits.
test_worktree_rm_name_mode_keeps_scratch() {
    local sb
    new_sandbox sb
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q ".worktrees/probe75" -b "probe75" HEAD 2>/dev/null
    _scr_seed "$sb" 75
    run_in "$sb" "$WT_RM" probe75
    assert_exit 0 "$RUN_RC" "name-mode worktree-rm succeeds"
    _scr_assert_present "$sb" 75 "name mode"
}

# A symlinked scratch dir is refused with a stderr warning; teardown still
# exits 0, the link's target is untouched, and the other gid is still removed.
test_worktree_rm_refuses_symlinked_scratch() {
    local sb
    new_sandbox sb
    _scr_seed "$sb" 76
    command mkdir -p "$sb/elsewhere"
    command printf 'keep\n' >"$sb/elsewhere/keep"
    command rm -rf "$sb/.cache/librarian-review/golem-76"
    command ln -s "$sb/elsewhere" "$sb/.cache/librarian-review/golem-76"
    run_in "$sb" "$WT_RM" 76
    assert_exit 0 "$RUN_RC" "a refused scratch dir never fails teardown"
    assert_contains "$RUN_OUT" "refusing to remove" "the refusal is announced"
    assert_file_exists "$sb/elsewhere/keep" "the symlink's target is untouched"
    _scr_gone "$sb/.cache/librarian-review/solo-76" "the other gid is still removed"
}

# The status files are resolved from the MAIN checkout root, not the cwd: a
# teardown launched from inside another worktree still finds them.
test_worktree_rm_status_files_resolve_from_root() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 77
    run_in "$sb" "$WT_NEW" 78
    _scr_seed "$sb" 77
    run_in "$sb/.worktrees/issue-78" "$WT_RM" 77
    assert_exit 0 "$RUN_RC" "worktree-rm from a sibling worktree succeeds"
    _scr_gone "$sb/.worktrees/.status/golem-77.json" "golem-77.json removed via the root"
    _scr_gone "$sb/.worktrees/.status/golem-77.work.jsonl" "golem-77.work.jsonl removed via the root"
}

# A status file that is not a regular file is refused, not followed: a symlink
# golem-N.json aimed outside keeps its target, a DIRECTORY golem-N.work.jsonl
# survives, each refusal warns, and teardown still exits 0.
test_worktree_rm_refuses_irregular_status_files() {
    local sb st="" link_kept="no"
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/.status/golem-79.work.jsonl" "$sb/elsewhere"
    command printf 'keep\n' >"$sb/elsewhere/status.json"
    command ln -s "$sb/elsewhere/status.json" "$sb/.worktrees/.status/golem-79.json"
    run_in "$sb" "$WT_RM" 79
    assert_exit 0 "$RUN_RC" "a refused status file never fails teardown"
    assert_contains "$RUN_OUT" "not removing $sb/.worktrees/.status/golem-79.json (not a regular file)" \
        "the symlinked status file's refusal is announced"
    assert_contains "$RUN_OUT" "not removing $sb/.worktrees/.status/golem-79.work.jsonl (not a regular file)" \
        "the directory registry's refusal is announced"
    assert_file_exists "$sb/elsewhere/status.json" "the symlink's target is untouched"
    if [ -L "$sb/.worktrees/.status/golem-79.json" ]; then link_kept="yes"; fi
    assert_equals "yes" "$link_kept" "the refused symlink is left in place"
    if [ -d "$sb/.worktrees/.status/golem-79.work.jsonl" ]; then st="dir"; fi
    assert_equals "dir" "$st" "the refused directory is left in place"
}

# An ABSOLUTE GOLEM_STATUS_DIR passes through untouched — joining the root onto
# it would name a path that exists nowhere, and the files there would leak. The
# relative .worktrees/.status copy is a control: it must NOT be the one removed.
test_worktree_rm_absolute_status_dir_passes_through() {
    local sb abs
    new_sandbox sb
    abs="$sb/abs-status"
    command mkdir -p "$abs" "$sb/.worktrees/.status"
    command printf '{}\n' >"$abs/golem-80.json"
    command printf '{}\n' >"$abs/golem-80.work.jsonl"
    command printf '{}\n' >"$sb/.worktrees/.status/golem-80.json"
    # run_in pins GOLEM_STATUS_DIR to the relative default, so this one case
    # spells the same scrubbed environment with the absolute dir instead.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR="$abs" \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_CARGO_CACHE_DIR="$sb/no-cargo-cache" \
            GOLEM_UV_CACHE_DIR="$sb/no-uv-cache" \
            "$REAL_BASH" "$WT_RM" 80 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "worktree-rm with an absolute status dir succeeds"
    _scr_gone "$abs/golem-80.json" "golem-80.json removed from the absolute status dir"
    _scr_gone "$abs/golem-80.work.jsonl" "golem-80.work.jsonl removed from the absolute status dir"
    assert_file_exists "$sb/.worktrees/.status/golem-80.json" \
        "the relative default dir is not consulted when the status dir is absolute"
}

# review-scratch.sh failing OUTRIGHT (exit 2 — here a relative HOME it refuses
# to guess from) stays best-effort: teardown exits 0 and the status files,
# which do not depend on HOME, are still removed.
test_worktree_rm_survives_a_failing_scratch_helper() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/.status"
    command printf '{}\n' >"$sb/.worktrees/.status/golem-81.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME=relative-home \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_CARGO_CACHE_DIR="$sb/no-cargo-cache" \
            GOLEM_UV_CACHE_DIR="$sb/no-uv-cache" \
            "$REAL_BASH" "$WT_RM" 81 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "a failing review-scratch.sh never fails teardown"
    assert_contains "$RUN_OUT" "HOME must be an absolute path" "the helper's refusal is visible"
    _scr_gone "$sb/.worktrees/.status/golem-81.json" "status files are still removed after the helper fails"
}
