# shellcheck shell=bash
# worktree-rm.sh — NAME-mode teardown tests (issue #1005).
#
# Before #1005, `worktree-rm.sh` took only an issue number and derived every path
# from it, so a worktree under any other name had no supported teardown: the
# script refused it as a non-number, and the raw `git worktree remove --force`
# that would otherwise clean it up is denied from the main session by the #662
# bash-guard. These cases pin the new name mode AND — the half that matters — that
# it inherited every refusal rather than becoming a way around them.
#
# A SEPARATE FRAGMENT ON PURPOSE. The natural home, 40-worktree-rm.sh, measures
# 1304 production LOC against a `high` budget of 1000 (plan-lens, 2026-09-11), so
# these land in a sibling rather than growing a file already over budget.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (WT_NEW / WT_RM / ...) and sources tests/lib/golem-sandbox.sh for the shared
# sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This fragment
# therefore only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.
#
# Note the sandbox pins GOLEM_BASE_REF=HEAD (golem-sandbox.sh), which is what the
# name-mode merge gate measures against.

# --- helpers ----------------------------------------------------------------

# sb_git <sandbox> <git-args...> — git inside the sandbox with the same env scrub
# run_in uses, so a tainted GIT_DIR in the test runner's own environment cannot
# redirect a fixture's setup into the outer repo.
sb_git() {
    local dir="$1"
    shift
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$dir" "$@"
}

# make_named_worktree <sandbox> <name> <branch>
# Creates a worktree the way the real litter was created — a raw `git worktree
# add` under a non-issue name — which is exactly the shape worktree-new.sh
# refuses and therefore never produces.
make_named_worktree() {
    local dir="$1" name="$2" branch="$3"
    sb_git "$dir" worktree add -q ".worktrees/$name" -b "$branch" HEAD 2>/dev/null
}

# --- argument gate ----------------------------------------------------------

# The gate must keep rejecting what cannot be a worktree name. `..` and `a/b` are
# the load-bearing two: `$GOLEM_WORKTREE_DIR/..` is the REPO ROOT, and a slashed
# argument escapes the worktree directory entirely, so either would aim a
# teardown at a tree full of real work. An empty argument is the bare-invocation
# case.
test_worktree_rm_named_rejects_path_arguments() {
    local sb
    new_sandbox sb

    run_in "$sb" "$WT_RM" ".."
    assert_exit 2 "$RUN_RC" "worktree-rm rejects '..' (would resolve to the repo root)"

    run_in "$sb" "$WT_RM" "."
    assert_exit 2 "$RUN_RC" "worktree-rm rejects '.' (would resolve to the worktree dir)"

    run_in "$sb" "$WT_RM" "a/b"
    assert_exit 2 "$RUN_RC" "worktree-rm rejects a slashed argument"
    assert_contains "$RUN_OUT" "no '/'" "explains that a name carries no slash"

    run_in "$sb" "$WT_RM" ""
    assert_exit 2 "$RUN_RC" "worktree-rm rejects an empty argument"

    run_in "$sb" "$WT_RM" "../../etc"
    assert_exit 2 "$RUN_RC" "worktree-rm rejects a traversal argument"
}

# Regression guard on the arg-gate rewrite: issue mode must be untouched. The old
# single `^[0-9]+$` test was replaced by a two-arm dispatch, and the cheapest way
# for that to go wrong is for a number to fall down the name arm — where the
# worktree path would be `.worktrees/34` rather than `.worktrees/issue-34`.
test_worktree_rm_named_issue_mode_unchanged() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 34
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    run_in "$sb" "$WT_RM" 34
    assert_exit 0 "$RUN_RC" "issue mode still tears down by number"
    assert_contains "$RUN_OUT" "removed worktree" "issue mode reports the removal"
    assert_contains "$RUN_OUT" "issue-34" "issue mode still resolves the issue-N path"
}

# An unknown name is a clean no-op, not an error — the same contract issue mode
# has for an absent issue.
test_worktree_rm_named_absent_is_noop() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_RM" "no-such-probe"
    assert_exit 0 "$RUN_RC" "an absent name is a clean no-op (exit 0)"
    assert_contains "$RUN_OUT" "nothing to remove" "reports nothing to remove"
    assert_not_contains "$RUN_OUT" "( / " "does not render an empty branch slot"
}

# --- the round trip ---------------------------------------------------------

# The issue's actual shape: a worktree whose branch name follows NO prefix
# convention (`tmp/okf-probe-890` under `okf-probe`). The branch must be resolved
# from git's registration — a prefix-derived guess would name a branch that does
# not exist and silently leave the real one behind, which is the "a branch no
# cleanup path will ever delete" half of the issue.
test_worktree_rm_named_round_trip() {
    local sb branches
    new_sandbox sb
    make_named_worktree "$sb" "okf-probe" "tmp/okf-probe-890"

    run_in "$sb" "$WT_RM" "okf-probe"
    assert_exit 0 "$RUN_RC" "name-mode teardown succeeds"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_contains "$RUN_OUT" "deleted branch tmp/okf-probe-890" \
        "deletes the branch RESOLVED from git, not one derived from the prefix"

    assert_true "[ ! -d '$sb/.worktrees/okf-probe' ]" "the worktree directory is gone"
    branches="$(sb_git "$sb" branch --list "tmp/okf-probe-890")"
    assert_equals "" "$branches" "the resolved branch is gone"
}

# A detached-HEAD worktree has no branch line in the porcelain at all. That must
# be a clean removal, not a failure — the parse returning nothing is a legitimate
# state, and the teardown still has a directory to free.
test_worktree_rm_named_detached_head_has_no_branch() {
    local sb
    new_sandbox sb
    sb_git "$sb" worktree add -q --detach ".worktrees/detached" HEAD 2>/dev/null

    run_in "$sb" "$WT_RM" "detached"
    assert_exit 0 "$RUN_RC" "a detached-HEAD worktree tears down cleanly"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_not_contains "$RUN_OUT" "deleted branch" "claims no branch deletion when there is none"
}

# The branch must come from the MATCHING stanza. With two registered worktrees,
# a flat scan for a `branch ` line returns whichever git listed first — so this
# fixture fails loudly if the stanza latch is ever dropped, by deleting the
# wrong worktree's branch (or none).
test_worktree_rm_named_resolves_the_right_stanza() {
    local sb branches
    new_sandbox sb
    make_named_worktree "$sb" "first-probe" "tmp/first-890"
    make_named_worktree "$sb" "second-probe" "tmp/second-891"

    run_in "$sb" "$WT_RM" "second-probe"
    assert_exit 0 "$RUN_RC" "teardown of the second worktree succeeds"
    assert_contains "$RUN_OUT" "deleted branch tmp/second-891" "deletes its OWN branch"
    assert_not_contains "$RUN_OUT" "tmp/first-890" "never touches the other worktree's branch"

    branches="$(sb_git "$sb" branch --list "tmp/first-890")"
    assert_not_empty "$branches" "the untouched worktree keeps its branch"
    assert_true "[ -d '$sb/.worktrees/first-probe' ]" "the untouched worktree survives"
}

# --- AC2: the refusals are INHERITED, not bypassed ---------------------------

# AC2, first half. The whole point of routing name mode through the same body is
# that the dirty check still fires. Planted, not asserted: a tracked file is
# modified and the teardown must refuse — AND leave everything in place, since a
# refusal that already removed something is not a refusal.
test_worktree_rm_named_refuses_dirty_worktree() {
    local sb branches
    new_sandbox sb
    make_named_worktree "$sb" "dirty-probe" "tmp/dirty-890"
    command printf 'uncommitted work\n' >"$sb/.worktrees/dirty-probe/seed.txt"

    run_in "$sb" "$WT_RM" "dirty-probe"
    assert_exit 1 "$RUN_RC" "name mode REFUSES a dirty worktree"
    assert_contains "$RUN_OUT" "uncommitted changes" "names uncommitted changes as the reason"

    assert_true "[ -d '$sb/.worktrees/dirty-probe' ]" "the refusal removed nothing"
    branches="$(sb_git "$sb" branch --list "tmp/dirty-890")"
    assert_not_empty "$branches" "the branch survives the refusal"
}

# An UNTRACKED file is uncommitted work too, and is the likelier shape for a
# scratch probe — the thing it was created to produce. Distinct from the tracked
# case because the two travel different arms of the status filter.
test_worktree_rm_named_refuses_untracked_work() {
    local sb
    new_sandbox sb
    make_named_worktree "$sb" "untracked-probe" "tmp/untracked-890"
    command printf 'probe output\n' >"$sb/.worktrees/untracked-probe/findings.txt"

    run_in "$sb" "$WT_RM" "untracked-probe"
    assert_exit 1 "$RUN_RC" "name mode REFUSES a worktree holding untracked work"
    assert_contains "$RUN_OUT" "uncommitted changes" "names uncommitted changes as the reason"
    assert_true "[ -f '$sb/.worktrees/untracked-probe/findings.txt' ]" \
        "the untracked file still exists"
}

# AC2, second half — and the one genuinely NEW destructive act this change adds.
# A scratch branch has no PR, no remote and no merge commit, so `branch -D` on an
# unmerged one is unrecoverable. The worktree is still removed (that is what frees
# the path and unblocks the operator); the BRANCH is kept, and said so loudly.
test_worktree_rm_named_keeps_an_unmerged_branch() {
    local sb branches
    new_sandbox sb
    make_named_worktree "$sb" "unmerged-probe" "tmp/unmerged-890"
    command printf 'real work\n' >"$sb/.worktrees/unmerged-probe/kept.txt"
    sb_git "$sb/.worktrees/unmerged-probe" add kept.txt
    sb_git "$sb/.worktrees/unmerged-probe" -c commit.gpgsign=false commit -qm "unmerged work" 2>/dev/null

    run_in "$sb" "$WT_RM" "unmerged-probe"
    assert_exit 0 "$RUN_RC" "the worktree is still removed (the path is freed)"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_contains "$RUN_OUT" "kept branch tmp/unmerged-890" "says the branch was KEPT"
    assert_contains "$RUN_OUT" "NOT merged" "explains why it was kept"
    assert_not_contains "$RUN_OUT" "deleted branch" "never claims a deletion it did not do"

    branches="$(sb_git "$sb" branch --list "tmp/unmerged-890")"
    assert_not_empty "$branches" "the unmerged branch SURVIVES teardown"
}

# The merge gate is name-mode-only, and that asymmetry is load-bearing rather
# than an oversight: a golem branch reaches teardown SQUASH-merged, so git reports
# it unmerged and gating issue mode would refuse to delete on every ordinary
# successful teardown. Pinned with a genuinely unmerged issue-N branch, which
# issue mode must still delete unconditionally.
test_worktree_rm_named_merge_gate_does_not_leak_into_issue_mode() {
    local sb branches
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 77
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'golem work\n' >"$sb/.worktrees/issue-77/work.txt"
    sb_git "$sb/.worktrees/issue-77" add work.txt
    sb_git "$sb/.worktrees/issue-77" -c commit.gpgsign=false commit -qm "work" 2>/dev/null

    run_in "$sb" "$WT_RM" 77
    assert_exit 0 "$RUN_RC" "issue-mode teardown succeeds"
    assert_contains "$RUN_OUT" "deleted branch" \
        "issue mode still deletes an UNMERGED branch (the squash-merge case)"
    assert_not_contains "$RUN_OUT" "kept branch" "issue mode never applies the merge gate"

    branches="$(sb_git "$sb" branch --list "feature/issue-77")"
    assert_equals "" "$branches" "the issue branch is gone"
}
