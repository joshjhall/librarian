#!/usr/bin/env bash
# worktree-rm-leftover.sh — the LEFTOVER-DIRECTORY cluster of worktree-rm.sh,
# extracted as a sourced fragment (issue #1096).
#
# Sourced, not executed. worktree-rm.sh sources it right after config.sh and
# bounded-run.sh:
#
#     # shellcheck source=./worktree-rm-leftover.sh
#     . "$SCRIPT_DIR/worktree-rm-leftover.sh"
#
# WHY THESE SIX TOGETHER. Every function here disposes of what is left on disk
# after git has DEREGISTERED a worktree, and they share one safety model —
# residue guard first, then remove, then quarantine (rename aside), then the
# `unwedge-worktree` fallback, never claiming a path freed unless it is:
#
#   sanitize_stderr               display-safe subprocess stderr
#   leftover_is_worktree_residue  the guard: inside the repo AND fingerprinted
#   remove_leftover_dir           remove, else quarantine to a `.wedged-*` sibling
#   unwedge_fallback              last resort when our own rename cannot run
#   cleanup_leftover_dir          guard + remove, refusing loudly on non-residue
#   adopt_if_deregistered         a failed `git worktree remove` that DID deregister
#
# THE PARENT'S GLOBALS this file touches (do not add more without listing them):
#
#   reads   root     the main-checkout root (adopt_if_deregistered)
#           wt       the worktree path relative to root (adopt_if_deregistered)
#   writes  removed  set to 1 once something was torn down (remove_leftover_dir,
#                    adopt_if_deregistered); worktree-rm.sh initializes it to 0
#
# Every function is only DEFINED here; nothing runs at source time, so the
# globals need only be assigned before the first call, not before the source.
#
# bash-3.2 clean, BSD-tool clean, per CLAUDE.md § Runtime policy.
#
# The two directives below are file-wide for the same reason as
# golem-status-signals.sh's: every hit is the one fact stated above.
# shellcheck disable=SC2154  # root/wt are assigned by the sourcing script
# shellcheck disable=SC2034  # removed is read by the sourcing script

# leftover_is_worktree_residue <root> <worktree> — true only when <worktree> is
# safe to `rm -rf` as the residue of a deregistered git worktree (#813 review).
#
# "git does not list it" is NOT sufficient evidence on its own, and getting this
# wrong is unrecoverable. Before this change an unlisted path was simply never
# touched, so the cleanup below is the script's first unconditional `rm -rf` and
# needs to earn it. Two independent things can go wrong:
#
#   never a worktree     `$wt` is `$GOLEM_WORKTREE_DIR/issue-$N`, a predictable
#                        path. An operator's scratch directory, a stray editor
#                        copy, or a worktree-new.sh run that crashed after
#                        `mkdir` but before `git worktree add` all look
#                        identical to genuine residue — and can hold real,
#                        never-tracked work that no git probe can see.
#   escaped the repo     GOLEM_WORKTREE_DIR is env-overridable and never
#                        validated. Set to an absolute path, `$wt` becomes
#                        absolute and the `rm -rf` lands wherever it points.
#
# So require BOTH: the path must resolve INSIDE the repo root (containment,
# which kills the absolute-path case and any `../` escape), and it must carry a
# worktree FINGERPRINT — a `.git` entry, even a broken one, since a deregistered
# worktree keeps its dangling `.git` file (that dangling pointer is the very
# state #813 is about). A directory with no `.git` at all was never a worktree,
# so it is left alone.
#
# Fails CLOSED and LOUD per this repo's convention: anything unrecognized is
# reported and kept, never deleted. Refusing costs an operator one manual `rm`;
# guessing wrong costs them their data.
# sanitize_stderr <text> — echo <text> with C0 controls and DEL stripped, so
# captured subprocess stderr can be shown to an operator without smuggling ANSI
# escapes or CR line-overwrites into their terminal (#813 review).
#
# TAB (\011) and NEWLINE (\012) are deliberately KEPT so a genuine multi-line
# error stays legible — which is why this is not `[:cntrl:]`, a class that would
# eat both. `\013-\037` is ONE contiguous range on purpose: enumerating it
# byte-by-byte previously skipped \015 (CR), which a terminal renders by
# returning the cursor to column 0, letting crafted text overwrite the line and
# read as something else entirely. The C1 range (\200-\237) is NOT stripped —
# those bytes are also UTF-8 continuation bytes, so removing them would corrupt
# any multibyte character in a path.
#
# Mirrors the tmux-stderr sanitizer below; both exist because this script echoes
# captured subprocess stderr that embeds PATHS, and a crafted filename is enough
# to reach a terminal. Octal ranges rather than named classes so GNU and BSD
# `tr` agree. `printf '%s'` keeps the format string fixed, so text containing a
# literal `%s` or a backslash is data, never format. `|| true` because a bare
# command substitution IS subject to `set -e`: were `tr` unavailable this would
# abort teardown at 127 AFTER the destructive git mutations, and sanitizing is
# best-effort diagnostics that must never fail teardown.
sanitize_stderr() {
    local text="$1" safe
    [ -n "$text" ] || return 0
    safe="$(command printf '%s' "$text" | command tr -d '\000-\010\013-\037\177' || true)"
    command printf '%s' "${safe:-(stderr present but unprintable)}"
}

# Echoes WHICH guard tripped so the caller's message can name the actual cause
# rather than reusing one sentence for three different states — the same
# principle this issue is about, applied to its own refusal. `residue` means
# safe to remove; every other value is a distinct refusal reason.
leftover_is_worktree_residue() {
    local rootdir="$1" wtdir="$2" wt_real root_real parent

    # A SYMLINK at the worktree path is never residue. Refusing it outright is
    # what closes the leaf-symlink bypass: the resolution below only canonicalizes
    # the PARENT, so a symlinked leaf would keep an in-repo-looking `wt_real`
    # while `[ -e "$wtdir/.git" ]` followed the link and let an out-of-tree
    # `.git` satisfy the fingerprint — containment satisfied by a lie. Today's
    # `rm -rf` would only unlink the link node, not recurse through it, but that
    # is a property of `rm`, not a guarantee this function makes; a future switch
    # to `find "$wt" -delete` or a `"$wt"/*` glob would silently reopen the
    # escape. worktree-new.sh never creates the worktree as a symlink, so a real
    # teardown loses nothing by refusing here.
    if [ -L "$wtdir" ]; then
        command echo "symlink"
        return 1
    fi

    # Resolve without requiring the path itself to be resolvable as a dir.
    parent="$(cd "$(command dirname "$wtdir")" 2>/dev/null && command pwd -P)" || {
        command echo "unresolvable"
        return 1
    }
    [ -n "$parent" ] || {
        command echo "unresolvable"
        return 1
    }
    wt_real="$parent/$(command basename "$wtdir")"
    root_real="$(cd "$rootdir" 2>/dev/null && command pwd -P)" || {
        command echo "unresolvable"
        return 1
    }
    [ -n "$root_real" ] || {
        command echo "unresolvable"
        return 1
    }

    # Containment: must sit strictly INSIDE the repo root, never at or above it.
    #
    # `"$root_real"` is QUOTED, so glob metacharacters in the repo path are
    # matched LITERALLY rather than as wildcards — a root at `/home/u/proj[12]`
    # matches only a literal `proj[12]`, never `proj1`/`proj2` (verified against
    # `*`, `?`, and `[...]` roots). The `/?*` tail requires at least one
    # character after the separator, so `wt_real == root_real` and any parent
    # both fall through to the refusal, as does the `/a/b` vs `/a/bb` prefix trap.
    case "$wt_real" in
        "$root_real"/?*) ;;
        *)
            command echo "outside-root"
            return 1
            ;;
    esac

    # Fingerprint: a worktree — even a deregistered one — has a `.git` entry.
    if [ ! -e "$wtdir/.git" ]; then
        command echo "no-fingerprint"
        return 1
    fi

    command echo "residue"
}

# remove_leftover_dir <worktree> — free a deregistered worktree's leftover
# path: delete it where the filesystem allows, and QUARANTINE it by rename where
# it does not (#834 tolerated the survivors; #936 frees the path regardless).
#
# TWO DIFFERENT ISSUES MEET AT THIS LINE, and conflating them loses one:
# #813 is about never MISREPORTING dirtiness — a probe that cannot run must not
# be reported as uncommitted work. This is about FILESYSTEM TOLERANCE during the
# removal itself: the classification was already correct and the removal was
# already authorized; the filesystem simply refuses part of it.
#
# THE FAULT IS VIRTIOFS, NOT BINDFS (#936 — this comment previously said
# bindfs, which points a reader at the wrong layer). On the macOS Docker mount
# stack, stale dentries whose inodes are gone return EBADF from `unlink`/`stat`
# while still appearing in `readdir` (~3,700 `target/debug/incremental/*.o`
# files in the #813 report). Measured in #936: unmounting the bindfs overlay in
# a private mount namespace leaves the entries failing IDENTICALLY on the bare
# virtiofs beneath, and a freshly established `mount -t virtiofs` in that
# namespace fails the same way — so it is not a container-side dentry cache
# either. The host virtiofsd has lost the inode mapping; NO in-container call
# repairs it, and no amount of bindfs reconfiguration will help. Do not go
# refactoring the FUSE layer looking for this.
#
# NOT MACOS-ONLY (#1017). The same shape — EBADF on `ls`/`stat`/`unlink`, with
# `lsof` showing no process holding the paths — reproduced on a LINUX
# devcontainer overlay, so the attribution above is the measured macOS
# mechanism rather than the full set of platforms that can produce it. The
# handling is platform-independent (tolerate, report, quarantine), so this
# widening is about not misleading the next reader into thinking a Linux
# occurrence means something different is wrong.
#
# Nothing is at risk: git has no record of those files, `.worktrees/` is
# gitignored, and the golem collision guard reads `git worktree list`, not the
# directory. So an undeletable directory is an EXPECTED outcome on that
# platform, not a fault — and teardown runs unattended, where a `WARNING` costs
# an operator an adjudication for a condition that is both expected and
# harmless.
#
# ORDER IS THE LOAD-BEARING PART, not the message. `rm -rf` does not stop at the
# first undeletable entry — it removes everything it CAN and reports failure at
# the end. A flat `rm -rf "$wt"` therefore deletes the worktree's dangling `.git`
# file (verified) while leaving the undeletable subtree behind, which destroys
# the exact fingerprint `leftover_is_worktree_residue` requires. A RE-RUN of
# teardown then takes the `no-fingerprint` arm and exits 1 with "may never have
# been a worktree" — a hard failure whose text is affirmatively false, and a
# strictly worse instance of the misreporting class #813 closed.
#
# So contents first, `.git` LAST, and only once the contents are fully gone. On
# a partial failure `.git` deliberately SURVIVES, keeping the directory
# recognizable as residue so a re-run is idempotent rather than a refusal. The
# residue guard is NOT relaxed to compensate: its fingerprint rule is what
# protects an operator's scratch directory from an unconditional `rm -rf`.
#
# Tolerating is not swallowing. What remains on disk is REPORTED — the count of
# surviving entries, or the distinct "could not remove the directory itself"
# when the directory was emptied but its own node would not go. Both are stated
# as observations, never as inferences about WHY something survived: the removal
# calls here are best-effort and report one status for many operations, so this
# function cannot distinguish "refused by the filesystem" from "never attempted"
# after the fact. Two review cycles were spent learning that — each attempt to
# scope the count by intent printed "0 undeletable entries remain" about a
# directory still plainly on disk.
#
# `find -exec rm -rf {} +` rather than a `"$wt"/*` glob: the glob misses
# dotfiles, and `.git` is precisely what must be controlled here. `-mindepth 1
# -maxdepth 1` keeps `$wt` itself out of the argument list. No `-name .git`
# recursion concern — the exclusion is depth-1 only, so a nested `.git` inside a
# submodule is still removed normally.
#
# QUARANTINE (#936). Tolerating the survivors was right, but it left the
# `issue-N` PATH occupied — and the path, not the bytes, is what callers need:
# `worktree-new.sh` refuses to reuse an occupied one ("fatal: … already
# exists"), so the issue becomes permanently un-workable on that machine until
# someone clears it by hand. The fix rests on a measured asymmetry: the wedged
# ENTRIES cannot be unlinked, but the CONTAINING DIRECTORY renames fine, and new
# files can be created and deleted inside the freed path normally (verified
# against two live remnants, #849/#850). So where the tree cannot be deleted it
# is moved aside instead, and the path is freed either way.
#
# Three properties of the destination, each load-bearing:
#
#   distinct per attempt   `.wedged-issue-N-<epoch>-<pid>`. A BARE name is not
#                          merely untidy — `mv a .wedged-a` twice puts the
#                          second tree INSIDE the first (`.wedged-a/a`,
#                          reproduced), nesting one wedged tree in another and
#                          hiding it from an operator's `ls`.
#   dotted                 `read-scope-guard.sh` derives peer worktrees as the
#                          `issue-*` siblings of its own root. An undotted
#                          `wedged-issue-N` would match that glob and register
#                          as a phantom peer; a leading `.` misses it for the
#                          same structural reason `.status` does.
#   a SIBLING              the rename must stay inside the same directory: it is
#                          one `rename(2)` on the same filesystem, which is what
#                          makes it succeed where unlinking the contents cannot.
#
# The rename CAN itself fail (measured: EACCES when the parent is unwritable),
# so it is not assumed — a failure falls through to the in-place reporting that
# preceded this change rather than announcing a quarantine that did not happen.
#
# NO DISK SPACE IS RECLAIMED, and the message must not imply otherwise. Summing
# live file sizes across both live remnants gave 0 bytes: every wedged entry is
# a name with no reachable inode. The multi-GB figure an operator sees is
# host-side space that only a host unlink or a Docker VM restart releases.
remove_leftover_dir() {
    local wtdir="$1" survivors quarantine

    command find "$wtdir" -mindepth 1 -maxdepth 1 ! -name .git \
        -exec rm -rf {} + 2>/dev/null || true

    # Gate the `.git` removal on the OBSERVED state, not on the exit status
    # above: `find -exec … +` reports failure for the whole batch, so a status
    # check cannot say whether anything actually survived, and `rm -rf`'s own
    # partial success makes the distinction invisible. Ask the filesystem
    # instead — if any non-`.git` entry remains, the fingerprint must stay.
    if [ -z "$(command find "$wtdir" -mindepth 1 -maxdepth 1 ! -name .git 2>/dev/null)" ]; then
        command rm -rf "$wtdir/.git" 2>/dev/null || true
        command rmdir "$wtdir" 2>/dev/null || true
    fi

    if [ ! -e "$wtdir" ]; then
        command echo "  removed leftover directory $wtdir"
        removed=1
        return 0
    fi

    # Still present. Teardown CONTINUES (removed=1, exit 0) to the branch and
    # tmux steps — the worktree is deregistered and nothing git-tracked remains,
    # which is the whole definition of done here.
    #
    # REPORT WHAT IS ON DISK, and let the two facts that matter carry the
    # message: how many entries remain, and whether the directory itself could
    # be removed. Two earlier attempts scoped this count cleverly — excluding
    # `.git` because it was "kept by choice" — and each printed the
    # self-contradictory "0 undeletable entries remain" about a directory the
    # operator can plainly see, once via a refused `.git` and once via a refused
    # `rmdir` on an emptied directory. Every such exclusion is a claim about WHY
    # something survived, and this function cannot know that: `rm -rf`/`rmdir`
    # are best-effort here and report one status for many operations. So it
    # states only what it can observe.
    #
    # The `.git` this function deliberately keeps IS counted, and the message
    # says so rather than silently netting it out — an operator who sees "1
    # entry" on a partial removal should be able to reconcile it with the one
    # file in the directory.
    survivors="$(command find "$wtdir" -mindepth 1 2>/dev/null |
        command wc -l | command tr -d '[:space:]')"
    if [ "$survivors" -eq 0 ]; then
        # Emptied, but the directory node itself would not go (an unwritable
        # parent is the realistic cause). Saying "0 entries remain" here would
        # describe a clean sweep while the directory is still on disk.
        command echo "  emptied leftover directory $wtdir, but could not remove the directory itself"
    elif [ "$survivors" -eq 1 ]; then
        command echo "  cleared leftover directory $wtdir (1 entry could not be removed)"
    else
        command echo "  cleared leftover directory $wtdir ($survivors entries could not be removed)"
    fi

    # Free the PATH by rename (#936). See the header for why the destination is
    # dotted, sibling, and distinct per attempt. `$$` disambiguates two teardowns
    # racing within the same second; the epoch alone does not.
    #
    # `date`/`$$` rather than `mktemp -d`: mktemp CREATES the destination, and
    # `mv` onto an existing directory moves the source INSIDE it — reintroducing
    # the nesting this naming exists to prevent.
    quarantine="$(command dirname "$wtdir")/.wedged-$(command basename "$wtdir")-$(command date -u +%s 2>/dev/null || command echo 0)-$$"
    if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
        # Belt-and-suspenders against the one failure mode this naming exists to
        # prevent. epoch+pid should never collide (one quarantine per process),
        # but `mv` onto an EXISTING directory silently moves the source INSIDE
        # it — so an occupied destination must never be handed to `mv` on the
        # strength of "should never happen". Refuse rather than nest.
        command echo "  $wtdir could not be moved aside ($quarantine is occupied)"
        unwedge_fallback "$wtdir"
    elif command mv "$wtdir" "$quarantine" 2>/dev/null; then
        command echo "  the path was still occupied, so it was moved aside to $quarantine"
        command echo "  $wtdir is free again (no disk space is reclaimed in-container —"
        command echo "   those entries are names with no reachable inode; only a host"
        command echo "   unlink or a Docker VM restart releases the space)"
    else
        # The rename is not assumed. Report the tree where it actually is rather
        # than claiming a quarantine that did not happen.
        command echo "  $wtdir could not be moved aside either"
        unwedge_fallback "$wtdir"
    fi
    command echo "  (expected on the macOS virtiofs mount stack, and reproduced on a Linux"
    command echo "   devcontainer overlay — nothing git-tracked is at risk)"
    removed=1
}

# unwedge_fallback <worktree> — last resort when remove_leftover_dir's own
# rename-aside did not happen (#1088): hand the path to the containers image's
# `unwedge-worktree` (containers >= 4.20) when it is on PATH, and relay what it
# says — it names the quarantine it chose, so the operator learns exactly where
# the tree went. OPTIONAL by construction: librarian also runs on a host Mac and
# bare Linux with no such command, where the in-place report below is all there
# is. Its quarantine is the same `.wedged-<base>-<stamp>-<pid>` sibling shape
# (dotted, per-attempt), so read-scope-guard.sh ignores it just as it ignores
# ours; its timestamp format differs, which also gives it a fresh destination
# when ours was the occupied one.
#
# Never `exit`s: whatever it reports, teardown continues — nothing git-tracked
# is at risk here, and the path is reported occupied rather than assumed free.
unwedge_fallback() {
    local wtdir="$1" out
    if command -v unwedge-worktree >/dev/null 2>&1; then
        if out="$(command unwedge-worktree "$wtdir" 2>&1)" && [ ! -e "$wtdir" ]; then
            command echo "  unwedge-worktree moved it aside instead:"
            command printf '%s\n' "$(sanitize_stderr "$out")" | command sed 's/^/    /'
            return 0
        fi
        command echo "  unwedge-worktree could not move it either: $(sanitize_stderr "$out")"
    fi
    command echo "  so the path $wtdir stays occupied"
}

# cleanup_leftover_dir <root> <worktree> — the whole leftover-directory
# sequence: residue guard, removal/quarantine, prune. Returns 0 when the caller
# should CONTINUE to the branch and tmux steps; EXITS 1 on a refusal.
#
# EXTRACTED BY #1017, which gave it a second caller. It was two top-level
# `listed -eq 0` blocks, reachable only by a teardown that found the worktree
# already deregistered on entry — so a LIVE golem worktree never reached it.
# That is the common case: `git worktree remove --force` deregisters the
# worktree and THEN fails the delete, and the force-failure branch below exited
# 1 at that point, leaving the `issue-N` path occupied and the #936 quarantine
# unreached. Four consecutive teardowns in one orchestrate run ended that way.
# The sequence is identical at both call sites, so it is one function rather
# than a copy that can drift.
#
# THE RESIDUE GUARD RUNS ON BOTH PATHS, and the force-failure caller does not
# get an exemption for having just seen git register the path. "git had it a
# moment ago" is an inference about a path this script is about to `rm -rf`,
# and the guard exists precisely because such inferences are what cost an
# operator their data (see leftover_is_worktree_residue's header). A refusal is
# equally correct at either call site: an unrecognized path is refused wherever
# it is found.
#
# THE LEAD-IN IS AN ARGUMENT, not something the caller echoes first, and it is
# printed only AFTER the guard passes. The two callers describe different
# situations — one found the worktree already gone, the other just deregistered
# it — but neither should announce "removing the leftover directory" ahead of a
# refusal that removes nothing. Echoing it at the call site would do exactly
# that, and the resulting transcript would state an action the script then
# declined to take: the misreporting class this whole region exists to avoid.
cleanup_leftover_dir() {
    local rootdir="$1" wtdir="$2" lead_in="$3" residue_reason
    residue_reason="$(leftover_is_worktree_residue "$rootdir" "$wtdir")" || true
    if [ "$residue_reason" != "residue" ]; then
        # Name the guard that actually tripped. One sentence covering all three
        # would misdescribe two of them — a symlinked path may well HAVE a valid
        # `.git` at its target and resolve inside the root, so telling the
        # operator to look for a missing fingerprint or an out-of-tree path
        # would be false on both counts. Misreporting a state you did not
        # evaluate is the very defect this issue exists to fix; the refusal must
        # not commit it.
        case "$residue_reason" in
            symlink)
                command echo "worktree-rm: $wtdir is a symlink, not a worktree directory." >&2
                command echo "  Teardown never deletes through a symlink." >&2
                ;;
            outside-root)
                command echo "worktree-rm: $wtdir resolves outside the repo root ($rootdir)." >&2
                command echo "  Check GOLEM_WORKTREE_DIR — teardown only removes paths inside the repo." >&2
                ;;
            no-fingerprint)
                command echo "worktree-rm: $wtdir has no .git entry, so it may never have been a worktree." >&2
                command echo "  It is not registered either, so there is nothing to confirm it is stale residue." >&2
                ;;
            *)
                command echo "worktree-rm: $wtdir could not be resolved for the residue check." >&2
                ;;
        esac
        command echo "  Refusing to delete it — inspect and remove by hand if it is stale." >&2
        exit 1
    fi

    # The condition here is `-e` alone while the refusal above is `-e || -L`,
    # and the asymmetry is deliberate: a symlink (dangling or not) can never
    # reach this point, because leftover_is_worktree_residue refuses every
    # symlink and the refusal above exits on that. Widening this one to match
    # would therefore change nothing today — but it would quietly become the
    # branch that `rm -rf`s a symlink if that guard were ever relaxed, so it
    # stays narrow on purpose.
    if [ -e "$wtdir" ]; then
        command echo "$lead_in" >&2
        remove_leftover_dir "$wtdir"
        command git worktree prune || true
    fi
}

# adopt_if_deregistered <lead-in> — called after a `git worktree remove` attempt
# FAILED. Re-read the registration and decide whether this run may adopt what is
# left: exit 1 (refusal) unless git confirms the path is deregistered, in which
# case clean the leftover and RETURN so teardown continues to branch and tmux.
#
# Shared by BOTH failure sites (#1088). The force failure was the first to get
# it (#1017), but the plain removal can deregister just as well, and the force
# re-check that follows it then reads `unverifiable` on a path that is no longer
# a work tree. Refusing there printed "Nothing was removed" about a worktree git
# had already dropped, with the branch and tmux session left behind. One
# function, so the two sites cannot drift apart again.
#
# Reads the globals `root` and `wt`; sets `removed` via its callees.
adopt_if_deregistered() {
    local lead_in="$1" post_rc post_list
    # FINISH THE TEARDOWN INSTEAD OF STOPPING HALF-DONE (#1017). A
    # failing `git worktree remove` usually DEREGISTERS the worktree
    # before reporting the failure (measured in #813 on git 2.55.0), which
    # leaves exactly the leftover-directory state `cleanup_leftover_dir`
    # handles — quarantine included. Before #1017 the force failure
    # exited 1 at that point, and the recovery (re-run the same
    # command, which then takes that block) lived only in a source
    # comment. Four consecutive teardowns in one orchestrate run ended
    # with an agent finishing by hand and inventing a worse quarantine
    # name than #936's, so the recovery was clearly not discoverable.
    #
    # RE-READ THE REGISTRATION RATHER THAN REUSING `listed`. The failed
    # removal is precisely the mutation that changes it, so the value captured
    # at the top of the script is wrong here by construction — it says
    # 1 in both the deregistered and the still-registered case. Same
    # here-string capture as that first read, and for the same #928
    # reason: piping into `grep -q` lets a match SIGPIPE the writer, and
    # pipefail then inverts "IS listed" into listed=0.
    #
    # FAIL CLOSED on a re-read that ERRORS, and note this needs its own
    # branch rather than falling out of the match (#1017 review). An
    # errored `git worktree list` yields an EMPTY capture, and an empty
    # capture does not match — which reads as "not listed" and routes
    # to the cleanup arm. That is failing OPEN: it hands a path to the
    # removal on the strength of a read that did not happen. (The
    # residue guard downstream would still have to pass, so this was
    # defense-in-depth rather than an exposure — but an earlier version
    # of this comment claimed the fail-closed property the code did not
    # have, which is the misreporting class this whole region exists to
    # avoid. Caught by test_worktree_rm_force_reread_failure_fails_closed,
    # written because the review noted the branch was untested.)
    #
    # So keep the STATUS, not just the output, and treat an unreadable
    # registration state as still-registered: refuse, and let the
    # operator look.
    post_rc=0
    post_list="$(command git worktree list --porcelain 2>/dev/null)" || post_rc=$?
    if [ "$post_rc" -ne 0 ] ||
        command grep -Fqx -- "worktree $root/$wt" <<<"$post_list"; then
        # Either git failed WITHOUT deregistering, or the re-read
        # could not be evaluated at all. Both mean there is no leftover
        # directory this run may adopt, so keep the refusal — but state
        # the next action, so this exit stops being the one that leaves
        # an operator guessing.
        #
        # The two are NOT reported with one sentence: claiming "still
        # registered" about a state that could not be read would assert
        # something unmeasured, which is the defect this region keeps
        # being filed about.
        #
        # NEITHER ARM CLAIMS "NOTHING WAS REMOVED" (#1088 review). This script
        # removed nothing, but the failed `git worktree remove` it ran may have
        # deleted part of the tree before failing — the disk contents were
        # never measured, so the message names what this script did and the
        # registration state, and leaves the directory's state to the operator.
        if [ "$post_rc" -ne 0 ]; then
            command echo "  Could not re-read the worktree list afterwards, so whether the" >&2
            command echo "  worktree is still registered is unknown; teardown removed nothing" >&2
            command echo "  itself, but git's failed attempt may have emptied part of the tree." >&2
        else
            command echo "  The worktree is still registered, so teardown stops here; git's" >&2
            command echo "  failed attempt may have emptied part of the tree." >&2
        fi
        command echo "  Next: inspect it, then retry — git -C $wt status; git worktree list" >&2
        exit 1
    fi

    # Deregistered by the failed removal. Nothing git-tracked is left
    # to lose, so teardown CONTINUES to the branch and tmux steps
    # either way. Which message it prints depends on whether anything
    # is actually still on disk.
    #
    # THE EXISTENCE GUARD MIRRORS THE `listed -eq 0` ENTRY, and it is not
    # redundant (#1017 review). `cleanup_leftover_dir` runs the residue
    # check BEFORE its own `-e` test, and the fingerprint arm of that
    # check is `[ ! -e "$wtdir/.git" ]` — which is equally true when
    # the whole directory is gone. So handing it an absent path exits 1
    # with "has no .git entry, so it may never have been a worktree"
    # about a path that both WAS a worktree and needs no cleanup:
    # a false refusal, and precisely the misreporting class #813/#834
    # exist to prevent. Reproduced before fixing, with a --force that
    # removed the tree completely and still exited non-zero.
    if [ -e "$wt" ] || [ -L "$wt" ]; then
        cleanup_leftover_dir "$root" "$wt" "$lead_in"
    else
        # Deregistered AND already gone: the removal actually completed
        # and the non-zero status was about something else. There is
        # nothing to clean, so say that rather than inventing residue.
        command echo "  The worktree WAS deregistered and its directory is already gone," >&2
        command echo "  so the removal completed despite the error — continuing teardown." >&2
        command git worktree prune || true
        removed=1
    fi
}
