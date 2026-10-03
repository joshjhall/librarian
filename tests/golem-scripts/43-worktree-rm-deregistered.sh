# shellcheck shell=bash
# worktree-rm.sh deregistered-remnant tests — the #1088 area.
#
# Split from 42-worktree-rm-wedged.sh on arrival (that fragment was already
# over the `sh` warning budget). This area covers the case where the PLAIN
# `git worktree remove` deregisters the worktree before failing, so the force
# re-check reads `unverifiable`, plus the `unwedge-worktree` fallback when
# teardown's own quarantine rename fails.
#
# Reuses make_undeletable / restore_undeletable / quarantine_of /
# ignore_build_dir from 42-worktree-rm-wedged.sh, which the entry point sources
# BEFORE this file (its fragment list is explicit and ordered). Sourced by
# tests/validate-golem-scripts.sh; this file only DEFINES test functions.

# --- #1088: the PLAIN removal deregisters, the force re-check reads it -------

# run_with_early_deregistering_git <sandbox> <issue-N> [extra-PATH-dir]
# The #1088 sequence, one step EARLIER than run_with_deregistering_git: here the
# PLAIN `git worktree remove` deregisters the worktree and then fails the
# delete. The force re-check that follows finds a path that is no longer a work
# tree, reads `unverifiable`, and — before #1088 — exited 1 with "Nothing was
# removed" while the registration was already gone and the branch and tmux
# session were left behind.
#
# `--force` is never reached on this path, so the stub has no arm for it; it
# forwards to real git like every other call, which keeps the post-failure
# `git worktree list` re-read genuine.
#
# The optional third argument is prepended to PATH, for the tests that shim
# `mv` or `unwedge-worktree`.
run_with_early_deregistering_git() {
    local sb="$1" n="$2" extra="${3:-}" real_git
    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<STUB
#!/usr/bin/env bash
# Test stub (#1088): the plain remove deregisters and THEN fails the delete.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command rm -rf "$sb/.git/worktrees/issue-$n"
    command echo "error: failed to delete '$sb/.worktrees/issue-$n': Bad file descriptor" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUB
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            PATH="${extra:+$extra:}$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" "$n" 2>&1)" || RUN_RC=$?
}

# The issue's reproduction. Pins every half of "Expected": the deregistered
# leftover is adopted (quarantined, path freed), teardown continues to the
# branch step, and the false "Nothing was removed" is never printed once the
# registration has changed.
test_worktree_rm_recheck_after_deregistration_completes_teardown() {
    local sb blocked wedged branches
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 150
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-150")"

    run_with_early_deregistering_git "$sb" 150
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" \
        "teardown completes after the plain removal deregistered the worktree"
    assert_not_contains "$RUN_OUT" "Nothing was removed" \
        "never claims nothing was removed once the registration has changed"
    assert_not_contains "$RUN_OUT" "Inspect: git -C" \
        "never points the operator at git -C on a path that is no longer a work tree"
    assert_contains "$RUN_OUT" "WAS deregistered by the first removal attempt" \
        "names WHICH attempt deregistered it"
    assert_contains "$RUN_OUT" "Bad file descriptor" \
        "surfaces git's actual error from the first attempt"
    wedged="$(quarantine_of "$sb/.worktrees/issue-150")"
    assert_not_empty "$wedged" "the wedged remnant is quarantined"
    assert_true "[ ! -e '$sb/.worktrees/issue-150' ]" \
        "the issue-150 path is free after teardown"
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" branch --list "feature/issue-150")"
    assert_equals "" "$branches" \
        "teardown CONTINUES to the branch step instead of exiting half-done"
}

# The no-residue end: the plain removal deregistered the worktree, failed, yet
# left nothing on disk. Same contract — exit 0, branch deleted — with the
# "already gone" wording rather than invented residue.
test_worktree_rm_recheck_after_deregistration_without_residue() {
    local sb real_git branches
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 151
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<STUB
#!/usr/bin/env bash
# Test stub (#1088): the plain remove deregisters, deletes the tree, and still
# exits non-zero.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command rm -rf "$sb/.git/worktrees/issue-151" "$sb/.worktrees/issue-151"
    command echo "fatal: STUBBED LATE FAILURE" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUB
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 151 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "a deregistered-and-gone worktree is not refused"
    assert_contains "$RUN_OUT" "directory is already gone" \
        "says the removal completed rather than inventing residue"
    assert_not_contains "$RUN_OUT" "Nothing was removed" \
        "never claims nothing was removed about a tree that is gone"
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" branch --list "feature/issue-151")"
    assert_equals "" "$branches" "the branch is still torn down"
}

# make_failing_mv <dir> — plant a `mv` shim in <dir> that fails every rename
# into a `.wedged-*` destination and forwards everything else. This forces
# remove_leftover_dir's OWN quarantine rename down its failure arm without
# touching permissions, so the `unwedge-worktree` fallback (#1088) is the only
# thing that can still free the path.
make_failing_mv() {
    local dir="$1" real_mv
    real_mv="$(command -v mv)"
    command mkdir -p "$dir"
    command cat >"$dir/mv" <<STUB
#!/usr/bin/env bash
case "\${2:-}" in
    */.wedged-*) command echo "mv: STUBBED RENAME FAILURE" >&2; exit 1 ;;
esac
exec "$real_mv" "\$@"
STUB
    command chmod +x "$dir/mv"
}

# The fallback arm (#1088): our rename failed, `unwedge-worktree` is on PATH,
# so it is handed the path and its own report — which names where the tree
# went — reaches the operator.
test_worktree_rm_quarantine_falls_back_to_unwedge_worktree() {
    local sb blocked shim real_mv
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 152
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-152")"

    real_mv="$(command -v mv)"
    shim="$sb/shim"
    make_failing_mv "$shim"
    # Stub unwedge-worktree: records its argv, then renames with the REAL `mv`
    # (bypassing the failing shim) to a destination outside our naming scheme,
    # so the assertions can tell its quarantine from ours.
    command cat >"$shim/unwedge-worktree" <<STUB
#!/usr/bin/env bash
command printf '%s\n' "\$*" >"$sb/unwedge.argv"
"$real_mv" "\$1" "\$(dirname "\$1")/.wedged-\$(basename "\$1")-STUBBED"
command echo "unwedge-worktree: moved \$1 -> STUB-DEST"
STUB
    command chmod +x "$shim/unwedge-worktree"

    run_with_early_deregistering_git "$sb" 152 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes through the fallback"
    assert_file_contains "$sb/unwedge.argv" ".worktrees/issue-152" \
        "unwedge-worktree is handed the worktree path"
    assert_contains "$RUN_OUT" "unwedge-worktree moved it aside instead" \
        "says the fallback, not our rename, freed the path"
    assert_contains "$RUN_OUT" "STUB-DEST" \
        "relays unwedge-worktree's own report of where the tree went"
    assert_true "[ ! -e '$sb/.worktrees/issue-152' ]" \
        "the issue-152 path is free after the fallback"
    assert_not_contains "$RUN_OUT" "stays occupied" \
        "never reports the path occupied once the fallback freed it"
}

# path_without <cmd> — echo $PATH with every directory that provides <cmd>
# replaced by a symlink farm of that directory MINUS <cmd>. Shadowing with a
# non-executable file does not work: `command -v` skips it and keeps searching,
# landing on the real binary further down PATH. Rebuilding PATH is the only way
# to reproduce a host where the command simply does not exist.
path_without() {
    local cmd="$1" farm_root="$2" out="" d i=0 farm f
    local IFS=:
    for d in $PATH; do
        if [ -n "$d" ] && [ -x "$d/$cmd" ]; then
            i=$((i + 1))
            farm="$farm_root/path$i"
            command mkdir -p "$farm"
            for f in "$d"/*; do
                [ "$(command basename "$f")" = "$cmd" ] && continue
                command ln -s "$f" "$farm/" 2>/dev/null || true
            done
            d="$farm"
        fi
        out="${out:+$out:}$d"
    done
    command echo "$out"
}

# The absent-binary arm: on a host Mac or bare Linux there is no
# `unwedge-worktree`, and teardown must report the path occupied — never
# claim a quarantine — and still complete.
test_worktree_rm_quarantine_without_unwedge_worktree_reports_occupied() {
    local sb blocked shim saved_path
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 153
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-153")"

    shim="$sb/shim"
    make_failing_mv "$shim"
    saved_path="$PATH"
    PATH="$(path_without unwedge-worktree "$sb/farm")"
    if command -v unwedge-worktree >/dev/null 2>&1; then
        PATH="$saved_path"
        restore_undeletable "$blocked"
        assert_true "false" "path_without failed to hide unwedge-worktree"
        return 0
    fi
    run_with_early_deregistering_git "$sb" 153 "$shim"
    PATH="$saved_path"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes with the path still occupied"
    assert_contains "$RUN_OUT" "so the path .worktrees/issue-153 stays occupied" \
        "reports the path occupied when no fallback exists"
    assert_not_contains "$RUN_OUT" "unwedge-worktree" \
        "never mentions a fallback that is not installed"
    assert_not_contains "$RUN_OUT" "moved aside to" \
        "never claims a quarantine that did not happen"
    assert_true "[ -e '$sb/.worktrees/issue-153' ]" \
        "the directory really is still there"
}

# The fallback-also-fails arm: unwedge-worktree is present but its rename
# fails too. Its error is relayed and the path is reported occupied — never
# freed on the strength of a fallback that did not move anything.
test_worktree_rm_failed_unwedge_fallback_reports_occupied() {
    local sb blocked shim
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 154
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-154")"

    shim="$sb/shim"
    make_failing_mv "$shim"
    command cat >"$shim/unwedge-worktree" <<'STUB'
#!/usr/bin/env bash
command echo "unwedge-worktree: STUBBED FALLBACK FAILURE" >&2
exit 1
STUB
    command chmod +x "$shim/unwedge-worktree"

    run_with_early_deregistering_git "$sb" 154 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown still completes"
    assert_contains "$RUN_OUT" "unwedge-worktree could not move it either" \
        "says the fallback was tried and failed"
    assert_contains "$RUN_OUT" "STUBBED FALLBACK FAILURE" \
        "relays the fallback's own error"
    assert_contains "$RUN_OUT" "stays occupied" \
        "reports the path occupied"
    assert_true "[ -e '$sb/.worktrees/issue-154' ]" \
        "the directory really is still there"
}

# The exit-0-but-nothing-moved arm: unwedge_fallback trusts the PATH, not the
# exit status. A fallback that reports success while the tree is still there
# must read as a failure — claiming the path free would be the misreporting
# class this whole region exists to prevent.
test_worktree_rm_unwedge_success_without_move_reports_occupied() {
    local sb blocked shim
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 155
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-155")"

    shim="$sb/shim"
    make_failing_mv "$shim"
    command cat >"$shim/unwedge-worktree" <<'STUB'
#!/usr/bin/env bash
command echo "unwedge-worktree: STUBBED CLAIM OF SUCCESS"
exit 0
STUB
    command chmod +x "$shim/unwedge-worktree"

    run_with_early_deregistering_git "$sb" 155 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown still completes"
    assert_contains "$RUN_OUT" "unwedge-worktree could not move it either" \
        "an exit-0 fallback that left the path in place is reported as a failure"
    assert_contains "$RUN_OUT" "stays occupied" "reports the path occupied"
    assert_not_contains "$RUN_OUT" "moved it aside instead" \
        "never claims the fallback freed a path that is still there"
    assert_true "[ -e '$sb/.worktrees/issue-155' ]" \
        "the directory really is still there"
}
