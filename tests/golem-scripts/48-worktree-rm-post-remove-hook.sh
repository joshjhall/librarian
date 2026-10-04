# shellcheck shell=bash
# worktree-rm.sh — POST-REMOVE HOOK tests (issue #1092).
#
# The hook is how a consumer repo prunes per-checkout artifacts it keeps OFF the
# worktree (containers#1005). Every automated teardown path calls worktree-rm.sh
# directly, so this is the only place such a prune can run. The cases pin the
# contract stated in worktree-rm.sh's header: which hook runs, that it runs ONCE
# and only after a real removal (never on a refusal), its arguments, and that a
# failing, hanging or unrunnable hook is a warning rather than a failed teardown.
#
# A SEPARATE FRAGMENT for the same reason as 47-worktree-rm-named.sh: the natural
# home, 40-worktree-rm.sh, is already over its production-LOC budget.
#
# Sourced by tests/validate-golem-scripts.sh, which defines WT_NEW / WT_RM and
# sources tests/lib/golem-sandbox.sh (new_sandbox / run_in) BEFORE this file.
# golem-sandbox.sh exports GOLEM_POST_REMOVE_HOOK="" so no operator hook leaks
# in; these cases opt in per call through _hook_rm.

# --- helpers ----------------------------------------------------------------

# _hook_rm <sandbox> <hook-or-empty> <arg> [timeout]
# run_in, but with GOLEM_POST_REMOVE_HOOK (and optionally its timeout) set for
# this one teardown. An empty hook leaves the repo-local fallback in play.
_hook_rm() {
    local dir="$1" hook="$2" arg="$3" tmo="${4:-300}"
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_CARGO_CACHE_DIR="$dir/no-cargo-cache" \
            GOLEM_UV_CACHE_DIR="$dir/no-uv-cache" \
            GOLEM_POST_REMOVE_HOOK="$hook" \
            GOLEM_POST_REMOVE_HOOK_TIMEOUT="$tmo" \
            "$REAL_BASH" "$WT_RM" "$arg" 2>&1)" || RUN_RC=$?
}

# _write_hook <path> <log> — an executable hook that APPENDS one line per call
# (`<mode>|$1|$2|$3`) to <log>, so a count of lines is a count of invocations.
# The log lives OUTSIDE the worktree being removed, so teardown cannot take it.
_write_hook() {
    local path="$1" log="$2"
    command mkdir -p "${path%/*}"
    command printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s\\n" "$GOLEM_WORKTREE_MODE" "$1" "$2" "$3" >>"%s"\n' \
        "$log" >"$path"
    command chmod +x "$path"
}

# _sb_root <sandbox> — the root as worktree-rm.sh sees it. repo_root() resolves
# through git, so on macOS (/var -> /private/var) the raw mktemp path differs.
_sb_root() {
    (cd "$1" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git rev-parse --show-toplevel)
}

_line_count() {
    if [ -f "$1" ]; then
        command wc -l <"$1" | command tr -d ' '
    else
        command echo 0
    fi
}

# --- cases ------------------------------------------------------------------

# AC1: runs ONCE after a successful issue-mode removal, with the documented args.
test_worktree_rm_post_remove_hook_runs_once_with_args() {
    local sb root log
    new_sandbox sb
    root="$(_sb_root "$sb")"
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    run_in "$sb" "$WT_NEW" 71

    _hook_rm "$sb" "$sb/hooks/post" 71
    assert_exit 0 "$RUN_RC" "teardown with a hook exits 0"
    assert_true "[ ! -e '$sb/.worktrees/issue-71' ]" "the worktree was removed"
    assert_equals "1" "$(_line_count "$log")" "the hook ran exactly once"
    assert_equals "issue|71|$root|$root/.worktrees/issue-71" "$(command cat "$log" 2>/dev/null)" \
        "the hook got mode, issue number, main-checkout root and worktree path"

    # The header promises cwd = the main-checkout root. Pinned separately so
    # _write_hook's record stays one stable shape for every other case.
    command printf '#!/usr/bin/env bash\npwd -P >"%s"\n' "$sb/cwd.log" >"$sb/hooks/cwd"
    command chmod +x "$sb/hooks/cwd"
    run_in "$sb" "$WT_NEW" 88
    _hook_rm "$sb" "$sb/hooks/cwd" 88
    assert_equals "$(cd "$root" && command pwd -P)" "$(command cat "$sb/cwd.log" 2>/dev/null)" \
        "the hook runs with the main-checkout root as its cwd"
}

# The directory-name spelling normalizes to issue mode, so the hook sees `71`.
test_worktree_rm_post_remove_hook_normalizes_issue_dir_spelling() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    run_in "$sb" "$WT_NEW" 72

    _hook_rm "$sb" "$sb/hooks/post" issue-72
    assert_exit 0 "$RUN_RC" "issue-72 teardown exits 0"
    assert_contains "$(command cat "$log" 2>/dev/null)" "issue|72|" \
        "\$1 is the normalized number, not 'issue-72'"
}

# Repo-local fallback: <root>/.golem/post-remove runs when no env hook is set,
# and the env hook WINS when both exist.
test_worktree_rm_post_remove_hook_repo_local_and_precedence() {
    local sb log_local log_env
    new_sandbox sb
    log_local="$sb/local.log"
    log_env="$sb/env.log"
    _write_hook "$sb/.golem/post-remove" "$log_local"

    run_in "$sb" "$WT_NEW" 73
    _hook_rm "$sb" "" 73
    assert_exit 0 "$RUN_RC" "teardown with only a repo-local hook exits 0"
    assert_equals "1" "$(_line_count "$log_local")" "the repo-local hook ran once"

    _write_hook "$sb/hooks/post" "$log_env"
    run_in "$sb" "$WT_NEW" 74
    _hook_rm "$sb" "$sb/hooks/post" 74
    assert_equals "1" "$(_line_count "$log_env")" "the env hook ran"
    assert_equals "1" "$(_line_count "$log_local")" \
        "the repo-local hook did NOT also run when the env hook is set"
}

# AC2: a dirty refusal never reaches the hook — the artifacts it would prune
# still belong to a worktree that is still there.
test_worktree_rm_post_remove_hook_skipped_on_dirty_refusal() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    run_in "$sb" "$WT_NEW" 75
    command printf 'wip\n' >"$sb/.worktrees/issue-75/seed.txt"

    _hook_rm "$sb" "$sb/hooks/post" 75
    assert_exit 1 "$RUN_RC" "the dirty worktree is refused"
    assert_true "[ -d '$sb/.worktrees/issue-75' ]" "the refused worktree survives"
    assert_true "[ ! -e '$log' ]" "the hook never ran on a dirty refusal"
}

# AC2: an UNVERIFIABLE refusal (listed, but its gitfile points nowhere) never
# reaches the hook either.
test_worktree_rm_post_remove_hook_skipped_on_unverifiable_refusal() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    run_in "$sb" "$WT_NEW" 76
    command printf 'gitdir: /nonexistent/admin/dir\n' >"$sb/.worktrees/issue-76/.git"

    _hook_rm "$sb" "$sb/hooks/post" 76
    assert_exit 1 "$RUN_RC" "the unverifiable worktree is refused"
    assert_contains "$RUN_OUT" "cannot verify" "refused as unverifiable (guards a vacuous pass)"
    assert_true "[ ! -e '$log' ]" "the hook never ran on an unverifiable refusal"
}

# A no-op teardown removed nothing, so there is nothing to clean up after.
test_worktree_rm_post_remove_hook_skipped_on_noop() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"

    _hook_rm "$sb" "$sb/hooks/post" 77
    assert_exit 0 "$RUN_RC" "a no-op teardown exits 0"
    assert_contains "$RUN_OUT" "nothing to remove" "it was a no-op (guards a vacuous pass)"
    assert_true "[ ! -e '$log' ]" "the hook did not run on a no-op"
}

# AC3: a failing hook is logged, not fatal.
test_worktree_rm_post_remove_hook_failure_warns_exit_0() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/hooks"
    command printf '#!/usr/bin/env bash\necho hook-said-this\nexit 3\n' >"$sb/hooks/post"
    command chmod +x "$sb/hooks/post"
    run_in "$sb" "$WT_NEW" 78

    _hook_rm "$sb" "$sb/hooks/post" 78
    assert_exit 0 "$RUN_RC" "a failing hook does not fail teardown"
    assert_contains "$RUN_OUT" "post-remove hook $sb/hooks/post exited 3" \
        "the warning names the hook and its exit code"
    assert_contains "$RUN_OUT" "hook-said-this" "the hook's own output is relayed"
    assert_true "[ ! -e '$sb/.worktrees/issue-78' ]" "the worktree is still removed"
}

# A hanging hook is bounded: teardown returns, warns, and exits 0. `exec sleep`
# so the killed pid IS the sleeper and no orphan holds a descriptor open.
test_worktree_rm_post_remove_hook_timeout_warns_exit_0() {
    local sb start elapsed
    new_sandbox sb
    command mkdir -p "$sb/hooks"
    command printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$sb/hooks/post"
    command chmod +x "$sb/hooks/post"
    run_in "$sb" "$WT_NEW" 79

    start="$(command date +%s)"
    _hook_rm "$sb" "$sb/hooks/post" 79 1
    elapsed=$(($(command date +%s) - start))
    assert_exit 0 "$RUN_RC" "a hanging hook does not fail teardown"
    assert_contains "$RUN_OUT" "timed out after 1s" "the timeout is reported"
    assert_true "[ $elapsed -lt 20 ]" "teardown returned well before the hook would have (${elapsed}s)"
}

# A named hook that cannot run is said out loud, and teardown still succeeds.
test_worktree_rm_post_remove_hook_not_executable_warns() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/hooks"
    command printf '#!/usr/bin/env bash\nexit 0\n' >"$sb/hooks/post"
    run_in "$sb" "$WT_NEW" 80

    _hook_rm "$sb" "$sb/hooks/post" 80
    assert_exit 0 "$RUN_RC" "an unrunnable hook does not fail teardown"
    assert_contains "$RUN_OUT" "is not an executable file" "the skip is reported"

    run_in "$sb" "$WT_NEW" 81
    _hook_rm "$sb" "$sb/hooks/absent" 81
    assert_exit 0 "$RUN_RC" "a missing hook path does not fail teardown"
    assert_contains "$RUN_OUT" "$sb/hooks/absent is not an executable file" \
        "a missing hook path is reported too"
}

# Non-interactive: the hook's stdin is not the caller's. A hook that reads stdin
# gets EOF at once instead of blocking on a terminal nobody is watching.
test_worktree_rm_post_remove_hook_stdin_is_closed() {
    local sb log
    new_sandbox sb
    log="$sb/stdin.log"
    command mkdir -p "$sb/hooks"
    command printf '#!/usr/bin/env bash\nif read -r line; then echo "got:$line" >"%s"; else echo eof >"%s"; fi\n' \
        "$log" "$log" >"$sb/hooks/post"
    command chmod +x "$sb/hooks/post"
    run_in "$sb" "$WT_NEW" 82

    # A here-string, not a pipe: a pipe would run _hook_rm in a subshell and
    # lose RUN_RC, making the exit assertion vacuous (#1092 review).
    _hook_rm "$sb" "$sb/hooks/post" 82 <<<"leaked"
    assert_exit 0 "$RUN_RC" "teardown exits 0"
    assert_true "[ ! -e '$sb/.worktrees/issue-82' ]" "the worktree was removed"
    assert_equals "eof" "$(command cat "$log" 2>/dev/null)" \
        "the hook read EOF, not the caller's stdin"
}

# Name mode: $1 is the name, $3 the named worktree's path, mode is `name`.
test_worktree_rm_post_remove_hook_name_mode_args() {
    local sb root log
    new_sandbox sb
    root="$(_sb_root "$sb")"
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q .worktrees/scratch -b scratch HEAD 2>/dev/null

    _hook_rm "$sb" "$sb/hooks/post" scratch
    assert_exit 0 "$RUN_RC" "name-mode teardown exits 0"
    assert_true "[ ! -e '$sb/.worktrees/scratch' ]" "the named worktree was removed"
    assert_equals "name|scratch|$root|$root/.worktrees/scratch" "$(command cat "$log" 2>/dev/null)" \
        "the hook got name mode, the name, the root and the worktree path"
}

# A bad timeout falls back to the default out loud — and the hook still runs.
# Without the validation a `0` or non-number would reach bounded_run's `sleep`.
test_worktree_rm_post_remove_hook_bad_timeout_falls_back() {
    local sb log bad n=83
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    for bad in abc 0; do
        run_in "$sb" "$WT_NEW" "$n"
        _hook_rm "$sb" "$sb/hooks/post" "$n" "$bad"
        assert_exit 0 "$RUN_RC" "timeout '$bad' does not fail teardown"
        assert_contains "$RUN_OUT" "GOLEM_POST_REMOVE_HOOK_TIMEOUT='$bad' is not a positive integer; using 300" \
            "timeout '$bad' is reported and replaced"
        n=$((n + 1))
    done
    assert_equals "2" "$(_line_count "$log")" "the hook still ran once per teardown"
}

# The repo-local fallback is held to the same rule as an env hook: a dangling
# symlink or a non-executable file there is reported, never skipped silently.
test_worktree_rm_post_remove_hook_repo_local_unrunnable_warns() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.golem"
    command ln -s "$sb/nowhere" "$sb/.golem/post-remove"
    run_in "$sb" "$WT_NEW" 85
    _hook_rm "$sb" "" 85
    assert_exit 0 "$RUN_RC" "a dangling repo-local hook does not fail teardown"
    assert_contains "$RUN_OUT" "post-remove is not an executable file" \
        "a dangling repo-local hook is reported"

    command rm -f "$sb/.golem/post-remove"
    command printf '#!/usr/bin/env bash\nexit 0\n' >"$sb/.golem/post-remove"
    run_in "$sb" "$WT_NEW" 86
    _hook_rm "$sb" "" 86
    assert_exit 0 "$RUN_RC" "a non-executable repo-local hook does not fail teardown"
    assert_contains "$RUN_OUT" "post-remove is not an executable file" \
        "a non-executable repo-local hook is reported"
}

# A core.worktree REPAIR is a mutation, but not a teardown: on a run that found
# no worktree to remove, the hook must not fire and prune artifacts for a
# worktree this run never touched (#1092 review).
test_worktree_rm_post_remove_hook_skipped_on_repair_only() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/post" "$log"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" config core.worktree "$sb/.worktrees/issue-87-gone"

    _hook_rm "$sb" "$sb/hooks/post" 87
    assert_exit 0 "$RUN_RC" "a repair-only run exits 0"
    assert_contains "$RUN_OUT" "repaired stale core.worktree" \
        "the repair happened (guards a vacuous pass)"
    assert_true "[ ! -e '$log' ]" "the hook did not run on a repair-only run"
}

# A repo-local hook that is a SYMLINK to an executable runs — the `-L` arm exists
# for the dangling case, and must not break the ordinary linked one.
test_worktree_rm_post_remove_hook_repo_local_symlink_runs() {
    local sb log
    new_sandbox sb
    log="$sb/hook.log"
    _write_hook "$sb/hooks/real" "$log"
    command mkdir -p "$sb/.golem"
    command ln -s "$sb/hooks/real" "$sb/.golem/post-remove"
    run_in "$sb" "$WT_NEW" 89

    _hook_rm "$sb" "" 89
    assert_exit 0 "$RUN_RC" "teardown with a linked repo-local hook exits 0"
    assert_equals "1" "$(_line_count "$log")" "the linked repo-local hook ran once"
}
