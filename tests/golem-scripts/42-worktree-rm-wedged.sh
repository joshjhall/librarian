# shellcheck shell=bash
# worktree-rm.sh wedged-tree tests — the #834/#936 area (issue #1017 split).
#
# Split out of 40-worktree-rm.sh, which had grown past the `sh` high budget of
# 1000 production LOC. The seam was already drawn in that file: this area owns
# the three undeletable-entry helpers below (make_undeletable,
# restore_undeletable, quarantine_of) and nothing outside it uses them, so the
# move is a pure relocation with no shared-helper fallout.
#
# Covers what teardown does when the filesystem REFUSES part of the removal:
# #834's tolerate-and-report, and #936's quarantine-by-rename that frees the
# `issue-N` path regardless. #1017 then made the registered-worktree force
# failure reach that same quarantine instead of exiting half-done.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- #834: partial leftover removal under a bindfs/FUSE overlay -------------

# make_undeletable <dir> — plant an undeletable entry under <dir> and echo the
# directory that must be chmod-restored afterwards.
#
# SIMULATION, and the issue permits it: the real trigger is a bindfs/FUSE
# overlay returning EBADF for `unlink` on stale dentries whose inodes are gone,
# which cannot be produced without that overlay. What the fix actually depends
# on is only that `rm -rf` FAILS on some entry while succeeding on its siblings,
# so an unwritable parent directory reproduces the shape exactly: `rm` cannot
# unlink a child of a directory it may not write, and carries on with the rest.
#
# Requires a non-root uid — root ignores the permission bits entirely and the
# removal would succeed, turning every test below into a tautology that passes
# with and without the fix. Callers skip rather than assert when running as root.
make_undeletable() {
    local dir="$1"
    command mkdir -p "$dir/target/debug/incremental"
    command touch "$dir/target/debug/incremental/stale.o"
    command chmod 500 "$dir/target/debug/incremental"
    command echo "$dir/target/debug/incremental"
}

# Restore write permission so the harness's `rm -rf "$WORKDIR"` EXIT trap can
# actually clean the sandbox — without this the undeletable fixture outlives the
# run and leaks a directory into $TMPDIR on every invocation.
#
# Restores BOTH the original path and the quarantined one (#936). Teardown now
# renames the wedged tree aside, so by the time a caller restores, the fixture
# usually no longer lives where `make_undeletable` put it. `chmod`ing only the
# old path is a silent no-op (it already ends in `|| true`), which is exactly
# how this leak would come back unnoticed — the caller's assertions all pass
# while the unwritable directory survives the run.
restore_undeletable() {
    local dir="$1" wt_dir
    command chmod 700 "$dir" 2>/dev/null || true
    # Teardown now RENAMES the wedged tree aside (#936), so by the time a caller
    # restores, the fixture usually no longer lives at the path it was planted
    # at — and `chmod`ing only that path is a silent no-op (it already ends in
    # `|| true`). Every assertion still passes while the unwritable directory
    # survives the run and leaks into $TMPDIR, which is exactly how the original
    # leak this helper exists to prevent would come back unnoticed.
    #
    # So restore the whole worktree DIRECTORY, which holds both the original
    # path and any `.wedged-*` sibling. Truncating at `/.worktrees/` rather than
    # walking up a fixed number of levels: callers plant fixtures at different
    # depths (`<wt>/target/debug/incremental`, `<wt>/.git/objects`, `<wt>`
    # itself), and a fixed walk is wrong for all but one of them.
    case "$dir" in
        */.worktrees/*)
            wt_dir="${dir%%/.worktrees/*}/.worktrees"
            command chmod -R 700 "$wt_dir" 2>/dev/null || true
            ;;
    esac
}

# quarantine_of <worktree-dir> — echo the single `.wedged-<base>-*` sibling that
# teardown moved <worktree-dir> aside to, or empty if there is none (#936).
#
# Globbed rather than reconstructed: the suffix carries an epoch and a pid the
# test cannot predict, and that unpredictability is the point (see the script's
# header — a predictable name nests the second quarantine inside the first).
quarantine_of() {
    local wtdir="$1" parent base hit
    parent="$(command dirname "$wtdir")"
    base="$(command basename "$wtdir")"
    for hit in "$parent/.wedged-$base-"*; do
        [ -d "$hit" ] || continue
        command echo "$hit"
        return 0
    done
    return 0
}

# #834: a partial removal is an EXPECTED outcome on a bindfs/FUSE overlay, not a
# fault — nothing git-tracked is at risk (git has no record of those files,
# .worktrees/ is gitignored, and the collision guard reads `git worktree list`).
# Teardown must therefore report success and CONTINUE to the branch/tmux steps,
# rather than emitting the WARNING an unattended operator would have to
# adjudicate. Pins exit 0, the absence of a warning, and that the branch is
# still deleted (the continue-past-it property, which a bare exit-code check
# would miss).
test_worktree_rm_partial_leftover_removal_is_tolerated() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 90
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-90"
    blocked="$(make_undeletable "$sb/.worktrees/issue-90")"

    run_in "$sb" "$WT_RM" 90
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "a partial leftover removal is tolerated, not a failure"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "no scary warning for a condition that is expected on this platform"
    # The COUNT is asserted exactly, not just its presence — a bare "contains a
    # number" assertion would pass for any scoping of the count. The fixture
    # leaves five entries on disk: `target`, `target/debug`,
    # `target/debug/incremental`, `stale.o`, and the `.git` this script keeps on
    # purpose. All five are counted, because the message reports what is
    # OBSERVABLE rather than asserting why each entry survived (see the
    # function's comment — two review cycles were spent on counts scoped by
    # intent, each of which could report zero for a surviving directory).
    assert_contains "$RUN_OUT" "5 entries could not be removed" \
        "reports every entry still on disk, including the .git it kept"
    assert_contains "$RUN_OUT" "virtiofs" "names the expected cause so it reads as benign"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" branch --list "feature/issue-90")"
    assert_equals "" "$branches" "teardown CONTINUES to the branch after a partial removal"
}

# #834, the ordering half — the defect a message-only fix would leave behind.
# `rm -rf` does not stop at the first undeletable entry: it removes everything
# it can, INCLUDING the deregistered worktree's dangling `.git` file, and only
# then reports failure. That destroys the fingerprint
# `leftover_is_worktree_residue` requires, so the directory stops being
# recognizable as worktree residue at all. Pinning `.git` survival is what makes
# the removal ORDER (contents first, .git last, and only once the contents are
# fully gone) a tested contract rather than an implementation detail.
test_worktree_rm_partial_removal_keeps_the_residue_fingerprint() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 91
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-91"
    blocked="$(make_undeletable "$sb/.worktrees/issue-91")"

    run_in "$sb" "$WT_RM" 91
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "the partial removal still succeeds"
    # The tree is quarantined by then (#936), so the fingerprint is asserted
    # where it now LIVES. The contract is unchanged — `.git` must survive the
    # contents pass — but a fix that deleted `.git` first would still be caught
    # here, because the quarantined tree would not carry it either.
    local wedged
    wedged="$(quarantine_of "$sb/.worktrees/issue-91")"
    assert_not_empty "$wedged" "the wedged tree was moved aside, not left in place"
    assert_true "[ -e '$wedged/.git' ]" \
        "the .git fingerprint SURVIVES a partial removal, keeping the dir recognizable"
    # The removal is still real: everything the filesystem allowed is gone.
    assert_true "[ ! -e '$wedged/seed.txt' ]" \
        "removable contents are still deleted — tolerating is not skipping"
}

# #834, the consequence the fingerprint exists to prevent. A re-run of teardown
# after a partial removal must stay a clean no-op. Before the ordering fix the
# first run deleted `.git`, so this second run took the `no-fingerprint` arm and
# exited 1 with "may never have been a worktree" — a HARD FAILURE, in unattended
# teardown, whose text is affirmatively false about a directory that was a
# worktree. That is the same misreporting class #813 closed, reached by a
# different route, which is why it is asserted here rather than left implied.
test_worktree_rm_rerun_after_partial_removal_is_idempotent() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 92
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-92"
    blocked="$(make_undeletable "$sb/.worktrees/issue-92")"

    run_in "$sb" "$WT_RM" 92
    assert_exit 0 "$RUN_RC" "the first teardown tolerates the partial removal"

    run_in "$sb" "$WT_RM" 92
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "a re-run after a partial removal is a clean no-op, not a refusal"
    assert_not_contains "$RUN_OUT" "may never have been a worktree" \
        "never tells the operator a real worktree's residue was never a worktree"
    assert_not_contains "$RUN_OUT" "Refusing to delete" \
        "the re-run does not refuse a directory this script itself left behind"
}

# #834 narrowness: the tolerance must not weaken the ORDINARY path. With nothing
# undeletable, a leftover directory is still removed COMPLETELY — `.git` and the
# directory itself included — and reports the plain success message with no
# partial-removal note. Without this, a fix that simply stopped removing `.git`
# would pass all three tests above while leaving residue on every normal
# teardown.
test_worktree_rm_full_leftover_removal_is_unchanged() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 93
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-93"

    run_in "$sb" "$WT_RM" 93
    assert_exit 0 "$RUN_RC" "an unimpeded leftover removal still succeeds"
    assert_true "[ ! -e '$sb/.worktrees/issue-93' ]" \
        "with nothing undeletable the directory is removed entirely, .git included"
    assert_contains "$RUN_OUT" "removed leftover directory" "reports the plain removal"
    assert_not_contains "$RUN_OUT" "undeletable entries remain" \
        "no partial-removal note when the removal was complete"
}

# #834 review cycle 1: the count must not exclude a `.git` the FILESYSTEM
# refused, only one this function deliberately kept.
#
# The two are reached by different routes and look identical at the end: in both
# the directory is still on disk with `.git` in it. But when the contents pass
# fully succeeded, the `.git` removal WAS attempted and failed, which is a
# genuine undeletable entry — while an unconditional exclusion reported
# "0 undeletable entries remain" about a directory that visibly survived
# (reproduced before the fix). A count that contradicts the directory's own
# existence is precisely the misreporting this script exists to avoid, so the
# branch is decided by the same observed state the removal was gated on.
#
# Fixture: everything outside `.git` is removable, and `.git` is a NON-EMPTY
# DIRECTORY whose inner dir is unwritable — the one shape `rm -rf` cannot
# remove. (A worktree's `.git` is normally a file; a directory here only has to
# be undeletable, not realistic.)
test_worktree_rm_counts_a_git_the_filesystem_refused() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 94
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-94"

    command rm -rf "$sb/.worktrees/issue-94/.git"
    command mkdir -p "$sb/.worktrees/issue-94/.git/objects"
    command touch "$sb/.worktrees/issue-94/.git/objects/blob"
    blocked="$sb/.worktrees/issue-94/.git/objects"
    command chmod 500 "$blocked"

    run_in "$sb" "$WT_RM" 94
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "an undeletable .git is still tolerated, not a failure"
    # The defining assertion: never report zero survivors for a directory that
    # is still on disk.
    assert_not_contains "$RUN_OUT" "0 entries" \
        "never reports zero entries while the directory survives"
    assert_contains "$RUN_OUT" "3 entries could not be removed" \
        "counts the refused .git subtree (.git, objects, blob) rather than excluding it"
    # The directory survived the REMOVAL — asserted where it now lives, since
    # #936 then moves it aside. The count above is what this case is really
    # about, and it is computed before the quarantine; the survival assertion
    # exists to keep that count honest, so it must follow the tree.
    assert_not_empty "$(quarantine_of "$sb/.worktrees/issue-94")" \
        "the directory really did survive the removal (quarantined, not deleted)"
}

# #834 review cycle 2: an EMPTIED but still-present directory gets its own
# message, never a count of zero.
#
# Third route to the same misreport, and the reason the count is no longer
# scoped by intent at all. Here the contents pass AND the `.git` removal both
# succeed, so the directory is genuinely empty — but `rmdir` fails because the
# PARENT is unwritable (removing a directory's contents needs write on the
# directory; removing the directory itself needs write on its parent). A count
# then reports 0 while the directory is plainly still on disk, which is the
# self-contradiction the previous two cycles each produced by a different route.
#
# Asserting the distinct wording is what pins the branch: a count-only message
# cannot express "emptied, but the node itself would not go".
test_worktree_rm_emptied_but_undeletable_dir_is_not_reported_as_zero() {
    local sb parent
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rmdir fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 96
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-96"

    # $wt stays writable (its contents can be cleared); its PARENT does not, so
    # the trailing rmdir on $wt fails.
    parent="$sb/.worktrees"
    command chmod 500 "$parent"

    run_in "$sb" "$WT_RM" 96
    restore_undeletable "$parent"

    assert_exit 0 "$RUN_RC" "an undeletable directory node is tolerated, not a failure"
    assert_not_contains "$RUN_OUT" "0 entries" \
        "never reports zero entries for a directory still on disk"
    assert_contains "$RUN_OUT" "could not remove the directory itself" \
        "names the actual condition: emptied, but the directory node would not go"
    assert_true "[ -e '$sb/.worktrees/issue-96' ]" "the directory really did survive"
    # This fixture is ALSO the only one that exercises the quarantine's
    # rename-FAILURE branch (#936), so it pins that branch's message here rather
    # than leaving the arm untested. An unwritable parent defeats `mv` for the
    # same reason it defeats `rmdir`: both the source unlink and the destination
    # create need write permission on that one directory. Verified live — the
    # run prints "could not be moved aside either".
    #
    # The negative assertion is the load-bearing half: without it, a regression
    # that swallowed the mv failure (dropping the `elif` and echoing the success
    # text unconditionally) would still satisfy every other line in this test
    # while telling an operator the path was freed when it plainly was not —
    # exactly the misreporting class #813 and #834 exist to prevent.
    assert_contains "$RUN_OUT" "could not be moved aside either" \
        "the rename-failure branch reports the tree where it actually is"
    assert_not_contains "$RUN_OUT" "moved aside to" \
        "never claims a quarantine that did not happen"
}

# #834 review cycles 1+2, the total-failure end of the range: NOTHING could be
# removed, including a plain-file `.git`.
#
# Covers the "genuine misconfiguration" case (a removal that accomplished
# nothing at all) and, with it, the realistic `.git`-as-a-FILE shape — a
# worktree's `.git` is normally a file, while the sibling test above has to make
# it a directory to keep it undeletable on its own.
#
# Why the two cannot be separated with permission bits: unlinking ANY direct
# child requires write on the parent directory, so the same `chmod` that saves
# `.git` necessarily saves its siblings too. A file-`.git`-refused-while-
# siblings-go fixture would need an immutable flag (`chattr +i`, root-only), so
# that split is genuinely unreachable here rather than merely untested — which
# is also why the message reports observable state instead of trying to
# attribute a reason to each survivor.
#
# The assertion that matters is the count: it must equal everything on disk,
# `.git` included. A count scoped to "entries the filesystem refused" would have
# to decide whether the never-attempted `.git` belongs, and both earlier
# attempts at that got it wrong.
test_worktree_rm_total_removal_failure_counts_everything() {
    local sb wt
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 97
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-97"

    wt="$sb/.worktrees/issue-97"
    command mkdir -p "$wt/sub"
    command touch "$wt/sub/f"
    # Unwritable worktree dir: no direct child can be unlinked, `.git` included.
    command chmod 500 "$wt"

    run_in "$sb" "$WT_RM" 97
    restore_undeletable "$wt"

    assert_exit 0 "$RUN_RC" "a total removal failure is still tolerated, not a hard failure"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "still no scary warning — the operator cannot act on this either"
    # Three survive: `.git`, `seed.txt` (worktree-new checks the seed commit
    # out), and `sub`. NOT `sub/f` — unlinking it needs write on `sub`, which is
    # untouched, so `rm -rf` reaches through and deletes it while the
    # directory-shaped `sub` above it stays. That asymmetry is why the count is
    # asserted against the observed tree rather than against "what the fixture
    # created": the two differ, and only the former is what the operator sees.
    assert_contains "$RUN_OUT" "3 entries could not be removed" \
        "counts every surviving entry, including the plain-file .git"
    # Survivors are asserted at the quarantined path (#936): the count above is
    # computed before the rename, and the tree it counted then moves. Following
    # it keeps this case pinning the same contract — which entries survived the
    # REMOVAL — rather than silently degrading to "the path is gone", which the
    # quarantine makes true for every implementation.
    local wedged
    wedged="$(quarantine_of "$wt")"
    assert_not_empty "$wedged" "the undeletable tree was moved aside, not lost"
    assert_true "[ -e '$wedged/.git' ]" "the file-shaped .git is among the survivors"
    assert_true "[ ! -e '$wedged/sub/f' ]" \
        "a nested file whose own parent stays writable is still removed"
}

# #834 review cycle 3: the n=1 boundary — exactly one entry survives.
#
# Two reasons this case is worth its own fixture. It reads correctly ("1 entry",
# not "1 entries"), and it is the numeric edge where an off-by-one in the
# survivor count would show up most plainly: the other fixtures assert 0, 3, and
# 5, none of which distinguishes a count from a count-plus-or-minus-one as
# obviously as the singular boundary does.
#
# Fixture: the worktree holds only the deliberately-kept `.git` plus one
# undeletable directory. `seed.txt` is removable and goes, leaving exactly one
# survivor beside `.git`... which is itself counted, so the total is 2. To get a
# true n=1 the `.git` must be the ONLY survivor — reached by making the worktree
# directory unwritable AFTER emptying everything else, which is what this does.
test_worktree_rm_single_survivor_reads_singular() {
    local sb wt
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 98
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-98"

    wt="$sb/.worktrees/issue-98"
    # Empty the worktree of everything except `.git`, then make the directory
    # unwritable so the one remaining entry cannot be unlinked either.
    command rm -f "$wt/seed.txt"
    command chmod 500 "$wt"

    run_in "$sb" "$WT_RM" 98
    restore_undeletable "$wt"

    assert_exit 0 "$RUN_RC" "a single undeletable entry is tolerated"
    assert_contains "$RUN_OUT" "1 entry could not be removed" \
        "reads singular at the n=1 boundary, and pins the count against an off-by-one"
    assert_not_contains "$RUN_OUT" "1 entries" \
        "never the ungrammatical plural"
}

# --- #936: quarantine a wedged worktree so the issue-N path is always freed ---

# The issue's core AC, and the reason the quarantine exists at all. #834 taught
# teardown to TOLERATE entries the filesystem will not unlink — correct, since
# nothing git-tracked is at risk — but tolerating left the `issue-N` PATH
# occupied, and the path is what callers actually need: `worktree-new.sh`
# refuses to reuse an occupied one ("already exists"), so the issue became
# permanently un-workable on that machine until someone cleared it by hand.
#
# Asserted as PATH FREED plus SIBLING PRESENT, not just one of them. "The
# directory is gone" alone would also pass for an implementation that deleted
# the tree outright — which cannot work here (that is the whole premise) and
# would destroy an operator's only copy of whatever is wedged.
test_worktree_rm_quarantines_a_wedged_worktree() {
    local sb blocked wedged
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 130
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-130"
    blocked="$(make_undeletable "$sb/.worktrees/issue-130")"

    run_in "$sb" "$WT_RM" 130
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "a wedged worktree is still a successful teardown"
    assert_true "[ ! -e '$sb/.worktrees/issue-130' ]" \
        "the issue-N PATH is freed even though its contents could not be unlinked"
    wedged="$(quarantine_of "$sb/.worktrees/issue-130")"
    assert_not_empty "$wedged" \
        "the tree is moved aside to a .wedged-* sibling, not deleted"
}

# The AC a delete-based implementation MUST fail. Freeing the path by `rm`ing
# harder is not an option (the entries cannot be unlinked — that is the premise),
# but an implementation that TRIED would still pass a bare "path is gone" check
# on a fixture where the wedge is simulated with permission bits. Pinning the
# CONTENTS at their new location is what makes this a rename.
test_worktree_rm_quarantine_preserves_contents() {
    local sb blocked wedged
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 131
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-131"
    blocked="$(make_undeletable "$sb/.worktrees/issue-131")"

    run_in "$sb" "$WT_RM" 131
    restore_undeletable "$blocked"

    wedged="$(quarantine_of "$sb/.worktrees/issue-131")"
    assert_not_empty "$wedged" "the tree was quarantined"
    # The undeletable entry itself is what a delete-based fix would destroy.
    assert_true "[ -e '$wedged/target/debug/incremental/stale.o' ]" \
        "the wedged entries SURVIVE the move — this is a rename, not a delete"
}

# The nesting hazard the timestamp+pid suffix exists to prevent, and the mutation
# this design is really about. Reproduced directly before the fix: with a BARE
# destination name, `mv a .wedged-a` twice puts the second tree INSIDE the first
# (`.wedged-a/a`) rather than beside it — because `mv` onto an EXISTING directory
# moves the source into it. That buries one wedged tree inside another, where an
# operator's `ls` will never show it.
#
# Asserted as "two siblings" AND "no .wedged-* nested inside a .wedged-*": the
# count alone would pass if a nested second quarantine still left two matches.
test_worktree_rm_two_quarantines_are_siblings_not_nested() {
    local sb blocked count nested
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb

    run_in "$sb" "$WT_NEW" 132
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-132"
    blocked="$(make_undeletable "$sb/.worktrees/issue-132")"
    run_in "$sb" "$WT_RM" 132
    assert_exit 0 "$RUN_RC" "the first teardown quarantines"

    # A SECOND wedged worktree at the same issue-N path — the realistic repeat,
    # since the path being reusable is exactly what the first quarantine bought.
    run_in "$sb" "$WT_NEW" 132
    assert_exit 0 "$RUN_RC" "the freed path is reusable — worktree-new succeeds again"
    command rm -rf "$sb/.git/worktrees/issue-132"
    blocked="$(make_undeletable "$sb/.worktrees/issue-132")"
    run_in "$sb" "$WT_RM" 132
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" "the second teardown quarantines too"
    count="$(command find "$sb/.worktrees" -maxdepth 1 -name '.wedged-issue-132-*' \
        2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_equals "2" "$count" "two quarantines land as two SIBLINGS"
    nested="$(command find "$sb/.worktrees" -path '*/.wedged-*/*' -name '.wedged-*' \
        2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_equals "0" "$nested" \
        "no quarantine is nested inside another — pins the distinct destination"
}

# Messaging AC: the operator must not read a freed path as freed SPACE. Summing
# live file sizes across both live remnants (#849/#850) gave 0 bytes — every
# wedged entry is a name with no reachable inode, so the multi-GB figure an
# operator sees is host-side space only a host unlink or a VM restart releases.
# A quarantine frees a PATH, and claiming otherwise sends someone hunting for
# disk that never came back.
test_worktree_rm_quarantine_does_not_claim_reclaimed_space() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 133
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-133"
    blocked="$(make_undeletable "$sb/.worktrees/issue-133")"

    run_in "$sb" "$WT_RM" 133
    restore_undeletable "$blocked"

    assert_contains "$RUN_OUT" "no disk space is reclaimed" \
        "states plainly that the path was freed but the space was not"
    # Still an EXPECTED condition, not an incident — the #834 property that an
    # unattended teardown must not hand its operator an adjudication.
    assert_not_contains "$RUN_OUT" "WARNING" \
        "quarantining stays a routine outcome, not a warning"
}

# Narrowness. Without this, an implementation that quarantined UNCONDITIONALLY —
# renaming aside on every teardown instead of only when removal failed — passes
# every case above while leaving a `.wedged-*` tree behind on each of the
# thousands of ordinary golem teardowns, silently filling the worktree dir.
test_worktree_rm_ordinary_teardown_never_quarantines() {
    local sb count
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 134
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-134"

    run_in "$sb" "$WT_RM" 134
    assert_exit 0 "$RUN_RC" "an unimpeded leftover removal still succeeds"
    count="$(command find "$sb/.worktrees" -maxdepth 1 -name '.wedged-*' \
        2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_equals "0" "$count" \
        "nothing is quarantined when the directory could simply be removed"
    assert_not_contains "$RUN_OUT" "moved aside" \
        "no quarantine message on the ordinary path"
}

# The quarantine must not become a way to move a symlink aside. The refusal lives
# UPSTREAM of remove_leftover_dir (leftover_is_worktree_residue refuses every
# symlink before the removal path is reached), so this asserts the property END
# TO END rather than re-deriving it: a symlinked worktree path is refused, its
# target is untouched, and — the part specific to #936 — the link itself is not
# renamed aside, which would "free" the path while unwedging nothing and
# stranding a live symlink under a `.wedged-*` name.
test_worktree_rm_never_quarantines_a_symlink() {
    local sb outside count
    new_sandbox sb
    outside="$(command mktemp -d "$WORKDIR/wedgelink.XXXXXX")" || return 1
    command printf 'OUTSIDE VIA SYMLINK\n' >"$outside/precious.txt"
    command touch "$outside/.git"
    command mkdir -p "$sb/.worktrees"
    command ln -s "$outside" "$sb/.worktrees/issue-135"

    run_in "$sb" "$WT_RM" 135

    assert_exit 1 "$RUN_RC" "a symlink at the worktree path is still refused"
    assert_true "[ -L '$sb/.worktrees/issue-135' ]" \
        "the symlink is left in place, not renamed aside"
    assert_file_contains "$outside/precious.txt" "OUTSIDE VIA SYMLINK" \
        "the symlink target is never touched"
    count="$(command find "$sb/.worktrees" -maxdepth 1 -name '.wedged-*' \
        2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_equals "0" "$count" "a refused symlink produces no quarantine"
}

# #936 item 3: the root-cause attribution in the code itself.
#
# The comment said the EBADF came from "the documented macOS/VirtioFS `bindfs`
# overlay", which points the next reader at the wrong layer — and #936 measured
# that unmounting bindfs in a private mount namespace leaves the entries failing
# identically on the bare virtiofs beneath, as does a freshly established
# virtiofs mount. The host virtiofsd has lost the inode mapping; no bindfs
# reconfiguration can fix it. Asserted against the SOURCE because the wrong
# attribution costs a future reader a refactor of a layer with nothing to fix,
# and nothing in the runtime output would ever reveal it.
test_worktree_rm_attributes_ebadf_to_virtiofs() {
    assert_file_contains "$WT_RM" "THE FAULT IS VIRTIOFS, NOT BINDFS" \
        "names the correct layer, and flags the correction for a reader who knows the old text"
    assert_file_contains "$WT_RM" "unmounting the bindfs overlay" \
        "records the measurement, so the next reader does not re-run it"
}

# --- #1017: a REGISTERED worktree's force failure must reach the quarantine ---

# ignore_build_dir <sandbox>
# Commit a `.gitignore` covering the `target/` tree `make_undeletable` plants,
# so the worktree reads CLEAN and teardown reaches the force path (#1017).
#
# Needed only by the REGISTERED cases. A still-registered worktree is dirty-
# checked up front, and an untracked `target/` makes that gate refuse with
# "has uncommitted changes" — a pass that never exercises the force branch at
# all (measured while writing these tests). The pre-existing cases in this file
# deregister the worktree first, so the gate is skipped and they never needed
# it.
#
# It is also what #813 actually saw: the undeletable entries were ~3,700
# `target/debug/incremental/*.o` files in a cargo build directory, which is
# gitignored in any real repo. An ignored build tree is the faithful fixture,
# not a convenience.
ignore_build_dir() {
    local sb="$1"
    command printf 'target/\n' >"$sb/.gitignore"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$sb" add .gitignore 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$sb" \
        -c commit.gpgsign=false commit -qm "ignore build dir" 2>/dev/null
}

# run_with_deregistering_git <sandbox> <issue-N>
# Run worktree-rm.sh against a `git` stub reproducing the exact two-stage
# failure this issue reports, verbatim from its transcript:
#
#   git said: fatal: working trees containing submodules cannot be moved or removed
#   then, with --force: error: failed to delete '…/issue-520': Bad file descriptor
#
# BOTH STAGES MATTER, and getting them wrong routes the run somewhere else
# entirely. The plain `git worktree remove` must fail WITHOUT deregistering —
# that is what carries execution into the force branch. Only the `--force`
# deregisters and then fails the delete, which is the state #1017 is about. A
# stub that deregistered on the plain remove instead would leave the worktree
# gone before the force re-check, and the run would exit at the `unverifiable`
# refusal — #880's path, not this one (measured while writing this test).
#
# A stub is the only way to drive it deterministically: the ordering is git's
# own (deregistration written before the delete is attempted, measured on git
# 2.55.0 in #813), so no permissions fixture can produce it. Everything else
# forwards to the real git, so the list, prune, status and branch calls around
# the removal are genuine — including the post-force `git worktree list`
# re-read that the fix turns on.
#
# The undeletable fixture is still real: `make_undeletable` is what makes the
# leftover directory survive the cleanup and reach the #936 rename, so the
# quarantine assertions are not tautologies.
run_with_deregistering_git() {
    local sb="$1" n="$2" real_git
    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<STUB
#!/usr/bin/env bash
# Test stub (#1017): the plain remove fails WITHOUT deregistering (git's
# submodule refusal); the --force deregisters and THEN fails the delete.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    if [ "\${3:-}" = "--force" ]; then
        command rm -rf "$sb/.git/worktrees/issue-$n"
        command echo "error: failed to delete '$sb/.worktrees/issue-$n': Bad file descriptor" >&2
        exit 128
    fi
    command echo "fatal: working trees containing submodules cannot be moved or removed" >&2
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
            "$REAL_BASH" "$WT_RM" "$n" 2>&1)" || RUN_RC=$?
}

# The issue's headline case. A LIVE golem worktree is still registered when
# teardown starts, so it takes the `listed -eq 1` arm — where the force
# deregisters it, fails the delete, and (before #1017) exited 1 without ever
# considering the #936 quarantine. `remove_leftover_dir` was reachable only
# from the `listed -eq 0` entry, which a live worktree never takes.
#
# Pins the AC that matters most operationally: `issue-N` is FREE when teardown
# ends, wedged or not. An occupied path makes `worktree-new.sh` refuse the
# issue ("fatal: … already exists"), which is precisely the un-workable-issue
# failure #936 was filed to prevent.
test_worktree_rm_registered_force_failure_reaches_quarantine() {
    local sb blocked wedged
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 140
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-140")"

    run_with_deregistering_git "$sb" 140
    restore_undeletable "$blocked"

    assert_exit 0 "$RUN_RC" \
        "teardown COMPLETES rather than exiting 1 half-done"
    wedged="$(quarantine_of "$sb/.worktrees/issue-140")"
    assert_not_empty "$wedged" \
        "the wedged tree reaches the #936 quarantine from the registered path too"
    assert_true "[ ! -e '$sb/.worktrees/issue-140' ]" \
        "the issue-140 path is free for worktree-new.sh after teardown"
    # The continue-past-it property: a bare exit-code check would miss that the
    # run must go on to the branch and tmux steps, exactly as the leftover path
    # does. Teardown ending "done" means all of teardown, not just the removal.
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" branch --list "feature/issue-140")"
    assert_equals "" "$branches" \
        "teardown CONTINUES to the branch step after adopting the leftover"
}

# The message half of the issue: an operator (or an agent) reading this output
# must not conclude the tool gave up half-way. That reading is what produced
# hand-rolled `rm -rf` and the `.trash-issue-520` name lacking #936's
# per-attempt uniqueness and dotted prefix.
#
# Also pins AC#5 in the ONE place it could newly regress: a message added by
# this change must not imply disk space came back. Wedged entries are names
# with no reachable inode; only a host unlink or a VM restart releases them.
test_worktree_rm_force_failure_states_the_recovery() {
    local sb blocked
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — permission bits cannot make rm fail"
        return 0
    fi
    new_sandbox sb
    ignore_build_dir "$sb"
    run_in "$sb" "$WT_NEW" 141
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    blocked="$(make_undeletable "$sb/.worktrees/issue-141")"

    run_with_deregistering_git "$sb" 141
    restore_undeletable "$blocked"

    assert_contains "$RUN_OUT" "WAS deregistered by the failed removal" \
        "states that the worktree is deregistered, not in an unknown state"
    assert_contains "$RUN_OUT" "holds nothing git-tracked" \
        "states the remnant is inert, so the teardown does not read as half-broken"
    # The cause still has to be reported — #813's contract, which this change
    # must not trade away for the new recovery text.
    assert_contains "$RUN_OUT" "Bad file descriptor" \
        "still surfaces git's actual error rather than swallowing it"
    assert_contains "$RUN_OUT" "no disk space is reclaimed" \
        "never implies the wedged entries freed space"
}

# The other side of the re-read, and the reason it is a re-read at all. When
# git fails WITHOUT deregistering, there is no leftover directory to adopt: the
# worktree is still registered, so falling through would hand `rm -rf` a path
# git still owns. That arm must keep refusing.
#
# Trusting the top-of-script `listed` instead of re-reading would get this
# exactly backwards — it says 1 in both cases, so every force failure would
# take the still-registered arm and the fix above would never fire.
#
# It also pins the issue's stated goal for this region: every exit states a
# next action. This one exits 1, so it owes the operator a command.
test_worktree_rm_force_failure_without_deregistration_still_refuses() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 142
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<STUB
#!/usr/bin/env bash
# Test stub: fail \`worktree remove\` WITHOUT deregistering (the contrast case).
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command echo "fatal: STUBBED REMOVAL FAILURE" >&2
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
            "$REAL_BASH" "$WT_RM" 142 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" \
        "a force failure that did NOT deregister still refuses"
    assert_contains "$RUN_OUT" "still registered and nothing was removed" \
        "says which state it is in, rather than leaving the operator to guess"
    assert_contains "$RUN_OUT" "Next:" \
        "the refusal states a next action, like every other exit in this region"
    assert_true "[ -e '$sb/.worktrees/issue-142' ]" \
        "the worktree git still owns is not removed"
    local count
    count="$(command find "$sb/.worktrees" -maxdepth 1 -name '.wedged-*' \
        2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_equals "0" "$count" \
        "a still-registered worktree is never quarantined"
}

# The fall-through does NOT get an exemption from the residue guard.
#
# The tempting shortcut is to skip `leftover_is_worktree_residue` on this path,
# reasoning that git listed the worktree moments ago so the path is obviously
# genuine. That is an INFERENCE about a path the script is about to `rm -rf`,
# and the guard exists because such inferences are what cost an operator their
# data — GOLEM_WORKTREE_DIR is env-overridable and never validated.
#
# Driven by removing the `.git` fingerprint along with the registration, which
# is the shape a flat `rm -rf` leaves behind (it deletes the dangling `.git`
# first and then fails on the undeletable subtree — the #834 ordering lesson).
test_worktree_rm_force_fallthrough_still_honors_the_residue_guard() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 143
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    # The precious file is planted BY THE STUB, not before the run. Writing it
    # up front would make the tree dirty, and teardown would refuse at the
    # up-front dirty gate — a pass that proves nothing about the fall-through,
    # which is never reached. Creating it at `worktree remove` time puts it
    # exactly where the real hazard is: work that exists on disk at the moment
    # the fingerprint is destroyed, with no git record of it anywhere.
    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<STUB
#!/usr/bin/env bash
# Test stub (#1017): same two-stage shape as run_with_deregistering_git, but
# the --force ALSO destroys the .git fingerprint — the state a flat
# \`rm -rf\` leaves behind (it deletes the dangling .git and then fails on the
# undeletable subtree, the #834 ordering lesson).
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    if [ "\${3:-}" = "--force" ]; then
        command printf 'NEVER-TRACKED WORK\n' >"$sb/.worktrees/issue-143/precious.txt"
        command rm -rf "$sb/.git/worktrees/issue-143" "$sb/.worktrees/issue-143/.git"
        command echo "error: failed to delete: Bad file descriptor" >&2
        exit 128
    fi
    command echo "fatal: working trees containing submodules cannot be moved or removed" >&2
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
            "$REAL_BASH" "$WT_RM" 143 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" \
        "an unrecognizable path is refused on the fall-through path too"
    assert_contains "$RUN_OUT" "may never have been a worktree" \
        "names the guard that actually tripped, rather than one message for three states"
    assert_file_contains "$sb/.worktrees/issue-143/precious.txt" "NEVER-TRACKED WORK" \
        "never-tracked work is kept, not rm -rf'd on the strength of a stale registration"
    # The lead-in must not precede a refusal: announcing "completing the
    # teardown now" and then declining to remove anything would state an action
    # the script did not take — the misreporting class this region is about.
    assert_not_contains "$RUN_OUT" "completing the teardown now" \
        "never announces a cleanup it then refuses to perform"
}
