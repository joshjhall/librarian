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

# --- review-cycle regressions (#1005 review) ---------------------------------

# The DIRECTORY-NAME spelling must behave exactly like the bare number.
#
# `issue-42` is what `ls .worktrees/` prints, so it is the spelling an operator
# reaches for — and it matched the name arm, where `wt` resolves to the SAME
# directory. That coincidence hid three divergences: `sess` became
# `golem-issue-42` (so the real tmux session was never killed), the REAPED event
# carried the wrong GOLEM_ID, and branch teardown took the name-mode merge gate
# — which KEEPS a squash-merged golem branch, the precise case issue mode's
# unconditional delete exists for.
#
# The fixture commits inside the worktree so the branch is genuinely unmerged:
# under the old behavior that printed "kept branch … NOT merged" on an ordinary
# teardown, which is what this asserts against.
test_worktree_rm_named_issue_prefix_routes_to_issue_mode() {
    local sb branches
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 42
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'golem work\n' >"$sb/.worktrees/issue-42/w.txt"
    sb_git "$sb/.worktrees/issue-42" add w.txt
    sb_git "$sb/.worktrees/issue-42" -c commit.gpgsign=false commit -qm w 2>/dev/null

    run_in "$sb" "$WT_RM" "issue-42"
    assert_exit 0 "$RUN_RC" "the directory-name spelling tears down"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_contains "$RUN_OUT" "deleted branch" \
        "deletes unconditionally like issue mode, NOT via the name-mode merge gate"
    assert_not_contains "$RUN_OUT" "kept branch" "never applies the merge gate to a golem branch"

    branches="$(sb_git "$sb" branch --list "feature/issue-42")"
    assert_equals "" "$branches" "the golem branch is gone"
}

# The merge gate must measure the BRANCH, not a same-named tag.
#
# `git rev-parse` resolves a bare name through its disambiguation order
# (refs/heads, refs/tags, …), so with both present it can return the TAG's
# target — measured on git 2.55.0, warning only on the stderr the script sends
# to /dev/null. The `branch -D` that follows is unambiguous, so the gate would
# have authorized deleting an UNMERGED branch by measuring a different object.
#
# The fixture is the dangerous shape specifically: the tag points at a commit
# that IS an ancestor of the base ref, while the branch tip is NOT. A gate
# reading the tag says "merged" and deletes; one reading the branch keeps it.
test_worktree_rm_named_merge_gate_ignores_a_same_named_tag() {
    local sb branches base
    new_sandbox sb
    base="$(sb_git "$sb" rev-parse HEAD)"
    make_named_worktree "$sb" "tag-probe" "scratch-x"
    command printf 'unmerged\n' >"$sb/.worktrees/tag-probe/u.txt"
    sb_git "$sb/.worktrees/tag-probe" add u.txt
    sb_git "$sb/.worktrees/tag-probe" -c commit.gpgsign=false commit -qm unmerged 2>/dev/null
    sb_git "$sb" -c tag.gpgsign=false tag -m t scratch-x "$base" 2>/dev/null

    run_in "$sb" "$WT_RM" "tag-probe"
    assert_exit 0 "$RUN_RC" "teardown proceeds"
    assert_contains "$RUN_OUT" "kept branch scratch-x" \
        "keeps the branch — the gate read refs/heads, not the same-named tag"
    assert_not_contains "$RUN_OUT" "deleted branch" "never deletes on a tag's authority"

    branches="$(sb_git "$sb" branch --list "scratch-x")"
    assert_not_empty "$branches" "the unmerged branch SURVIVES despite the ambiguous tag"
}

# The gate's THIRD arm: neither SHA resolves, so it fails CLOSED.
#
# The sandbox pins GOLEM_BASE_REF=HEAD, which is precisely why this arm cannot
# fire under the other fixtures — it needs a base ref that does not resolve at
# all. Untested defensive code is the shape this repo files issues about, so it
# gets a fixture rather than a claim.
test_worktree_rm_named_unresolvable_base_ref_keeps_branch() {
    local sb branches out rc=0
    new_sandbox sb
    make_named_worktree "$sb" "noref-probe" "tmp/noref-890"

    out="$(cd "$sb" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        HOME="$sb" TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
        GOLEM_WORKTREE_DIR=.worktrees \
        GOLEM_STATUS_DIR=.worktrees/.status \
        GOLEM_BASE_REF=refs/heads/does-not-exist \
        GOLEM_WORKTREE_LOCAL_FILES="" \
        "$REAL_BASH" "$WT_RM" "noref-probe" 2>&1)" || rc=$?

    assert_exit 0 "$rc" "teardown still frees the path"
    assert_contains "$out" "removed worktree" "reports the worktree removal"
    assert_contains "$out" "could not resolve it against" "names the unresolvable base ref"
    assert_not_contains "$out" "deleted branch" "fails CLOSED — no deletion on an unreadable gate"

    branches="$(sb_git "$sb" branch --list "tmp/noref-890")"
    assert_not_empty "$branches" "the branch survives an unresolvable base ref"
}

# --- base-ref resolution arms (#1005 review cycle 2) -------------------------

# run_wt_rm_with_base <sandbox> <base-ref> <arg> — invoke worktree-rm.sh with a
# custom GOLEM_BASE_REF, mirroring run_in's env exactly (#1005 review cycle 2).
#
# run_in hardcodes GOLEM_BASE_REF=HEAD, and `HEAD` resolves through NEITHER
# qualified arm — it matches only the bare fallback. So every fixture above
# exercises exactly one of the three resolution arms, and the two this fix ADDED
# were covered by no passing test. That is the silence-reads-as-a-pass shape, so
# the arms get driven directly.
#
# Mirrors run_in's variable set rather than a hand-picked subset: GOLEM_PLUGIN_PROBE
# and GOLEM_CARGO_CACHE_DIR are included because omitting them lets the script see
# the REAL host's values, which is how a sandbox stops being hermetic.
run_wt_rm_with_base() {
    local dir="$1" base="$2" arg="$3"
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF="$base" \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_CARGO_CACHE_DIR="$dir/no-cargo-cache" \
            "$REAL_BASH" "$WT_RM" "$arg" 2>&1)" || RUN_RC=$?
}

# ARM 1 — a bare LOCAL BRANCH name resolves via refs/heads and still gates.
# The branch under teardown is merged into that base, so a working arm DELETES;
# an arm that failed to resolve would print "could not resolve" instead, which is
# what makes this a positive test of the arm rather than of the fallback.
test_worktree_rm_named_base_ref_resolves_local_branch() {
    local sb branches
    new_sandbox sb
    sb_git "$sb" branch integration 2>/dev/null
    make_named_worktree "$sb" "lb-probe" "tmp/lb-890"

    run_wt_rm_with_base "$sb" "integration" "lb-probe"
    assert_exit 0 "$RUN_RC" "teardown succeeds against a local-branch base"
    assert_contains "$RUN_OUT" "deleted branch tmp/lb-890" \
        "refs/heads/<base> resolved, so the merged branch was deleted"
    assert_not_contains "$RUN_OUT" "could not resolve" "the local-branch arm resolved"

    branches="$(sb_git "$sb" branch --list "tmp/lb-890")"
    assert_equals "" "$branches" "the merged branch is gone"
}

# ARM 1 vs ARM 2 PRECEDENCE — refs/heads must win over refs/remotes.
#
# Cycle 2 flagged the original order (remotes first): `GOLEM_BASE_REF=main` would
# resolve against a remote literally named `main` before the local branch.
#
# THE FIXTURE HAS TO DIVERGE, not merely differ. A first attempt pointed the two
# refs at different commits but left the probe an ancestor of BOTH — so either
# arm deleted and the test proved nothing about precedence. Here the local and
# remote refs sit on genuinely divergent histories from a common seed, and the
# probe forks from the LOCAL tip: it is merged into refs/heads/pick-me and NOT
# into refs/remotes/pick-me. Reading the remote says "NOT merged" and keeps the
# branch; reading refs/heads deletes it. So this assertion flips if the
# precedence is ever reverted.
test_worktree_rm_named_base_ref_prefers_local_over_remote() {
    local sb branches seed local_tip divergent
    new_sandbox sb
    seed="$(sb_git "$sb" rev-parse HEAD)"

    # Local line of history, and the local `pick-me` at its tip.
    command printf 'local work\n' >"$sb/local.txt"
    sb_git "$sb" add local.txt
    sb_git "$sb" -c commit.gpgsign=false commit -qm localwork 2>/dev/null
    local_tip="$(sb_git "$sb" rev-parse HEAD)"
    sb_git "$sb" branch pick-me "$local_tip" 2>/dev/null

    # A DIVERGENT line from the same seed, and a remote-tracking `pick-me` on it.
    sb_git "$sb" checkout -q --detach "$seed" 2>/dev/null
    command printf 'remote work\n' >"$sb/remote.txt"
    sb_git "$sb" add remote.txt
    sb_git "$sb" -c commit.gpgsign=false commit -qm remotework 2>/dev/null
    divergent="$(sb_git "$sb" rev-parse HEAD)"
    sb_git "$sb" update-ref refs/remotes/pick-me "$divergent" 2>/dev/null
    sb_git "$sb" checkout -q "$local_tip" 2>/dev/null

    # The probe forks from the LOCAL tip: merged into refs/heads, not refs/remotes.
    sb_git "$sb" worktree add -q ".worktrees/prec-probe" -b "tmp/prec-890" "$local_tip" 2>/dev/null

    run_wt_rm_with_base "$sb" "pick-me" "prec-probe"
    assert_exit 0 "$RUN_RC" "teardown completes against the colliding base name"
    assert_contains "$RUN_OUT" "deleted branch tmp/prec-890" \
        "refs/heads/pick-me won over the divergent refs/remotes/pick-me"
    assert_not_contains "$RUN_OUT" "NOT merged" "the local base was the one measured against"

    branches="$(sb_git "$sb" branch --list "tmp/prec-890")"
    assert_equals "" "$branches" "the branch merged into the LOCAL base is gone"
}

# ARM 3 — a TAG as GOLEM_BASE_REF resolves via refs/tags.
# A consuming repo may legitimately pin the base to a release tag. Without this
# arm such a value reached only the bare fallback; with the ambiguity check now
# on that fallback, an unqualified tag lookup is exactly the case that must keep
# working through a NAMED arm rather than by luck.
test_worktree_rm_named_base_ref_resolves_tag() {
    local sb branches
    new_sandbox sb
    sb_git "$sb" -c tag.gpgsign=false tag -m r v1.0.0 HEAD 2>/dev/null
    make_named_worktree "$sb" "tagbase-probe" "tmp/tagbase-890"

    run_wt_rm_with_base "$sb" "v1.0.0" "tagbase-probe"
    assert_exit 0 "$RUN_RC" "teardown succeeds against a tag base"
    assert_contains "$RUN_OUT" "deleted branch tmp/tagbase-890" \
        "refs/tags/<base> resolved, so the merged branch was deleted"
    assert_not_contains "$RUN_OUT" "could not resolve" "the tag arm resolved"

    branches="$(sb_git "$sb" branch --list "tmp/tagbase-890")"
    assert_equals "" "$branches" "the merged branch is gone"
}

# AN AMBIGUOUS BARE BASE IS REFUSED, not silently measured against.
#
# The comment this replaced CLAIMED a wrong base "lands on the fail-closed side".
# That is false in general: it holds only when the wrong commit is an ANCESTOR of
# the true base. So the bare fallback now captures git's `warning: refname ... is
# ambiguous` and treats an ambiguous base as unresolvable. The fixture makes
# `collide` name BOTH a branch and a tag, neither reachable by a qualified arm
# (the qualified spellings are tried first and would each resolve, so the name is
# put somewhere only the bare form reaches: refs/collide).
test_worktree_rm_named_ambiguous_base_ref_is_refused() {
    local sb branches
    new_sandbox sb
    sb_git "$sb" update-ref refs/collide HEAD 2>/dev/null
    sb_git "$sb" update-ref refs/remotes/collide/HEAD HEAD 2>/dev/null
    make_named_worktree "$sb" "amb-probe" "tmp/amb-890"

    run_wt_rm_with_base "$sb" "collide" "amb-probe"
    assert_exit 0 "$RUN_RC" "teardown still frees the worktree path"
    assert_contains "$RUN_OUT" "removed worktree" "the worktree is removed"
    assert_not_contains "$RUN_OUT" "deleted branch" \
        "an ambiguous base never authorizes a deletion"

    branches="$(sb_git "$sb" branch --list "tmp/amb-890")"
    assert_not_empty "$branches" "the branch survives an ambiguous base ref"
}

# An `issue-<non-digit>` spelling stays in NAME mode.
# The new elif is anchored `^issue-[0-9]+$`, so `issue-probe` is an ordinary
# worktree name and must keep name mode's resolve-plus-merge-gate. Without this,
# a later loosening of that regex to `issue-.*` would silently route scratch
# worktrees into the unconditional-delete path.
test_worktree_rm_named_issue_nondigit_stays_in_name_mode() {
    local sb branches
    new_sandbox sb
    make_named_worktree "$sb" "issue-probe" "tmp/issue-probe-890"
    command printf 'unmerged\n' >"$sb/.worktrees/issue-probe/u.txt"
    sb_git "$sb/.worktrees/issue-probe" add u.txt
    sb_git "$sb/.worktrees/issue-probe" -c commit.gpgsign=false commit -qm u 2>/dev/null

    run_in "$sb" "$WT_RM" "issue-probe"
    assert_exit 0 "$RUN_RC" "teardown completes"
    assert_contains "$RUN_OUT" "kept branch tmp/issue-probe-890" \
        "issue-<non-digit> kept NAME mode's merge gate"
    assert_not_contains "$RUN_OUT" "deleted branch" "no unconditional issue-mode delete"

    branches="$(sb_git "$sb" branch --list "tmp/issue-probe-890")"
    assert_not_empty "$branches" "the unmerged scratch branch survives"
}
