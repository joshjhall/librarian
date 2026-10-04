# shellcheck shell=bash
# worktree-rm.sh rename-aside tests — the #1096 area.
#
# Two things the #1088 fallback left uncovered or unbounded: the
# quarantine-destination-OCCUPIED arm of remove_leftover_dir (its name embeds
# `date -u +%s` and `$$`, so it cannot be pre-created without stubbing), and the
# time bound now wrapped around both renames (our `mv` and `unwedge-worktree`),
# whose every outcome must be read from the filesystem, never from the status.
#
# Reuses make_undeletable / restore_undeletable / ignore_build_dir from
# 42-worktree-rm-wedged.sh and make_failing_mv / run_with_early_deregistering_git
# from 43-worktree-rm-deregistered.sh, which the entry point sources BEFORE this
# file (its fragment list is explicit and ordered). Sourced by
# tests/validate-golem-scripts.sh; this file only DEFINES test functions.

# skip_if_root — permission bits cannot make rm fail for root, so every case
# here (which needs an undeletable leftover) is meaningless under it.
skip_if_root() {
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    return 1
}

# write_stub <path> <body> — an executable bash stub.
write_stub() {
    command printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
    command chmod +x "$1"
}

# The occupied-destination arm (#1096 item 2). The quarantine name is
# `.wedged-<base>-<epoch>-<pid>`; a `date` shim pins the epoch to 4242 and, the
# first time it runs, pre-creates the destination so the `-e` check finds it.
# The pid is `$$` of the worktree-rm.sh shell, which is the shim's parent or
# grandparent depending on whether bash forks a subshell for the `$( … || … )`
# list, so the shim occupies BOTH candidates rather than guessing.
#
# Each occupant holds a marker file. Pinned: the fallback ran, the path was
# freed, and the tree never landed INSIDE an occupant — the nesting `mv` onto an
# existing directory would cause, which is the whole reason the arm refuses.
test_worktree_rm_occupied_quarantine_falls_back_to_unwedge_worktree() {
    local sb blocked shim real_mv real_date occ nested
    skip_if_root && return 0
    if ! command -v ps >/dev/null 2>&1; then
        skip_test "no ps — cannot resolve the pid the quarantine name embeds"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 160
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-160")"

    real_mv="$(command -v mv)"
    real_date="$(command -v date)"
    shim="$sb/shim"
    command mkdir -p "$shim"
    write_stub "$shim/date" "if [ \"\$*\" != '-u +%s' ]; then exec \"$real_date\" \"\$@\"; fi
if [ ! -e '$sb/occupied.done' ]; then
    : >'$sb/occupied.done'
    gp=\"\$(command ps -o ppid= -p \"\$PPID\" | command tr -d '[:space:]')\"
    for pid in \"\$PPID\" \"\$gp\"; do
        [ -n \"\$pid\" ] || continue
        command mkdir -p '$sb/.worktrees/.wedged-issue-160-4242-'\"\$pid\"
        : >'$sb/.worktrees/.wedged-issue-160-4242-'\"\$pid\"/OCCUPANT
    done
fi
command echo 4242"
    write_stub "$shim/unwedge-worktree" "command printf '%s\n' \"\$*\" >'$sb/unwedge.argv'
\"$real_mv\" \"\$1\" \"\$(dirname \"\$1\")/.wedged-\$(basename \"\$1\")-STUBBED\"
command echo \"unwedge-worktree: moved \$1 -> STUB-DEST\""

    run_with_early_deregistering_git "$sb" 160 "$shim"
    restore_undeletable "$blocked"

    assert_file_exists "$sb/occupied.done" "the date shim ran, so the stamp was pinned"
    assert_exit 0 "$RUN_RC" "teardown completes through the fallback"
    assert_contains "$RUN_OUT" "is occupied)" \
        "reports the occupied destination rather than renaming onto it"
    assert_file_contains "$sb/unwedge.argv" ".worktrees/issue-160" \
        "unwedge-worktree is handed the worktree path"
    assert_contains "$RUN_OUT" "unwedge-worktree moved it aside instead" \
        "says the fallback freed the path"
    assert_true "[ ! -e '$sb/.worktrees/issue-160' ]" \
        "the issue-160 path is free after the fallback"
    nested=0
    for occ in "$sb/.worktrees/.wedged-issue-160-4242-"*; do
        [ -e "$occ/issue-160" ] && nested=1
    done
    assert_equals "0" "$nested" "the tree never nested inside an occupant"
}

# Our rename HANGS (#1096 item 3): the bound fires, the timeout is reported AS a
# timeout — never as the path being freed — and the unwedge-worktree fallback
# still runs and frees it. The elapsed-time ceiling is what proves the bound:
# without it the shim's 30s sleep would run to completion.
test_worktree_rm_hanging_quarantine_rename_is_bounded() {
    local sb blocked shim real_mv start elapsed
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 161
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-161")"

    real_mv="$(command -v mv)"
    shim="$sb/shim"
    command mkdir -p "$shim"
    write_stub "$shim/mv" "case \"\${2:-}\" in */.wedged-*) exec sleep 30 ;; esac
exec \"$real_mv\" \"\$@\""
    write_stub "$shim/unwedge-worktree" "\"$real_mv\" \"\$1\" \"\$(dirname \"\$1\")/.wedged-\$(basename \"\$1\")-STUBBED\"
command echo \"unwedge-worktree: moved \$1 -> STUB-DEST\""

    start="$SECONDS"
    GOLEM_RENAME_TIMEOUT=1 run_with_early_deregistering_git "$sb" 161 "$shim"
    elapsed=$((SECONDS - start))
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_true "[ $elapsed -lt 25 ]" "the hung rename was cut off by the bound (${elapsed}s)"
    assert_contains "$RUN_OUT" "moving .worktrees/issue-161 aside timed out after 1s" \
        "reports the timeout as a timeout"
    assert_not_contains "$RUN_OUT" "moved aside to" \
        "never claims our rename landed"
    assert_contains "$RUN_OUT" "unwedge-worktree moved it aside instead" \
        "the fallback still runs after the timeout"
    assert_true "[ ! -e '$sb/.worktrees/issue-161' ]" "the path is free"
}

# A rename the bound interrupted may still have LANDED (rename(2) is atomic, so
# it is all or nothing, and the hang can come after it). The verdict is read
# from the paths, so a landed rename is reported as the quarantine it is — not
# as a timeout, and not handed to the fallback for a path that is already free.
test_worktree_rm_rename_landed_before_timeout_reports_the_quarantine() {
    local sb blocked shim real_mv
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 162
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-162")"

    real_mv="$(command -v mv)"
    shim="$sb/shim"
    command mkdir -p "$shim"
    write_stub "$shim/mv" "case \"\${2:-}\" in */.wedged-*) \"$real_mv\" \"\$@\"; exec sleep 30 ;; esac
exec \"$real_mv\" \"\$@\""
    write_stub "$shim/unwedge-worktree" ": >'$sb/unwedge.ran'"

    GOLEM_RENAME_TIMEOUT=1 run_with_early_deregistering_git "$sb" 162 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_contains "$RUN_OUT" "moved aside to" \
        "reports the quarantine that actually happened"
    assert_not_contains "$RUN_OUT" "timed out" \
        "a rename that landed is not reported as a timeout"
    assert_true "[ ! -e '$sb/unwedge.ran' ]" \
        "the fallback is not run for a path already freed"
}

# unwedge-worktree HANGS: bounded too, reported as a timeout, and the path is
# reported occupied — a killed fallback must never read as one that freed it.
test_worktree_rm_hanging_unwedge_fallback_is_bounded() {
    local sb blocked shim start elapsed
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 163
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-163")"

    shim="$sb/shim"
    make_failing_mv "$shim"
    write_stub "$shim/unwedge-worktree" "exec sleep 30"

    start="$SECONDS"
    GOLEM_RENAME_TIMEOUT=1 run_with_early_deregistering_git "$sb" 163 "$shim"
    elapsed=$((SECONDS - start))
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown still completes"
    assert_true "[ $elapsed -lt 25 ]" "the hung fallback was cut off by the bound (${elapsed}s)"
    assert_contains "$RUN_OUT" "unwedge-worktree timed out after 1s without moving it" \
        "reports the fallback's timeout as a timeout"
    assert_contains "$RUN_OUT" "so the path .worktrees/issue-163 stays occupied" \
        "reports the path occupied"
    assert_not_contains "$RUN_OUT" "moved it aside" \
        "never claims the fallback freed the path"
    assert_true "[ -e '$sb/.worktrees/issue-163' ]" "the directory really is still there"
}

# unwedge-worktree is killed by the bound AFTER its rename landed: the path IS
# free, so saying "stays occupied" would be false — but its report naming the
# destination never arrived, so none may be invented either.
test_worktree_rm_unwedge_timeout_after_move_reports_path_free() {
    local sb blocked shim real_mv
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 164
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-164")"

    real_mv="$(command -v mv)"
    shim="$sb/shim"
    make_failing_mv "$shim"
    write_stub "$shim/unwedge-worktree" "\"$real_mv\" \"\$1\" \"\$(dirname \"\$1\")/.wedged-\$(basename \"\$1\")-STUBBED\"
exec sleep 30"

    GOLEM_RENAME_TIMEOUT=1 run_with_early_deregistering_git "$sb" 164 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_contains "$RUN_OUT" "unwedge-worktree timed out after 1s, but .worktrees/issue-164 is gone" \
        "reports both the timeout and the freed path"
    assert_not_contains "$RUN_OUT" "stays occupied" \
        "never reports a freed path as occupied"
    assert_true "[ ! -e '$sb/.worktrees/issue-164' ]" "the path is free"
}

# A malformed GOLEM_RENAME_TIMEOUT warns and falls back to 30 — it neither
# aborts teardown under `set -u`/arithmetic nor silently unbounds the rename.
test_worktree_rm_invalid_rename_timeout_warns_and_defaults() {
    local sb blocked shim
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 165
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-165")"

    shim="$sb/shim"
    make_failing_mv "$shim"
    write_stub "$shim/unwedge-worktree" "command echo 'unwedge-worktree: STUBBED FAILURE' >&2; exit 1"

    GOLEM_RENAME_TIMEOUT=soon run_with_early_deregistering_git "$sb" 165 "$shim"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_contains "$RUN_OUT" "GOLEM_RENAME_TIMEOUT='soon' is not a positive integer; using 30" \
        "warns about the malformed bound"
    assert_contains "$RUN_OUT" "stays occupied" "the run otherwise proceeds as normal"
}

# rename_timeout's VALUE, not just its warning: the test above pins the message,
# whose "using 30" text is a literal — it would still print if the reset were
# dropped and the malformed value reached bounded_run. Drive the helper directly
# and assert what it hands the renames.
run_rename_timeout() {
    /usr/bin/env -uBASH_ENV "$REAL_BASH" -c '
        . "$1"
        . "$2"
        rename_timeout
    ' _ "$SCRIPTS/bounded-run.sh" "$WT_RM_LEFTOVER" 2>/dev/null
}

test_worktree_rm_rename_timeout_value() {
    assert_equals "30" "$(GOLEM_RENAME_TIMEOUT=soon run_rename_timeout)" \
        "a malformed bound resolves to 30, not the malformed value"
    assert_equals "30" "$(GOLEM_RENAME_TIMEOUT=0 run_rename_timeout)" \
        "zero is rejected — it would make every rename an instant timeout"
    assert_equals "30" "$(GOLEM_RENAME_TIMEOUT='' run_rename_timeout)" \
        "an empty bound resolves to 30"
    assert_equals "7" "$(GOLEM_RENAME_TIMEOUT=7 run_rename_timeout)" \
        "a valid bound passes through unchanged"
}

# bounded_run cannot bound (no `sleep` on PATH): the rename must still RUN,
# unbounded, with a warning — skipping it would leave the path occupied to
# protect against a hang nobody measured (the #543 shape).
test_worktree_rm_rename_runs_unbounded_without_bounded_run() {
    local sb blocked saved_path
    skip_if_root && return 0
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 166
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-166")"

    saved_path="$PATH"
    PATH="$(path_without sleep "$sb/farm")"
    if command -v sleep >/dev/null 2>&1; then
        PATH="$saved_path"
        restore_undeletable "$blocked"
        assert_true "false" "path_without failed to hide sleep"
        return 0
    fi
    run_with_early_deregistering_git "$sb" 166
    PATH="$saved_path"
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_contains "$RUN_OUT" "cannot bound the rename-aside (sleep/mktemp/cat missing); running it unbounded" \
        "warns that the rename is unbounded"
    assert_contains "$RUN_OUT" "moved aside to" "the rename still ran and quarantined the tree"
    assert_true "[ ! -e '$sb/.worktrees/issue-166' ]" "the path is free"
}
