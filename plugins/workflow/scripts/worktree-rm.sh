#!/usr/bin/env bash
# worktree-rm.sh — post-merge cleanup: remove the issue-N worktree and its
# branch (clean no-op if absent).
#
# Replaces the containers `worktree-rm` just recipe so the golem/worktree flow
# runs WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Removes <GOLEM_WORKTREE_DIR>/issue-N, deletes branch <GOLEM_BRANCH_PREFIX>N,
# and kills the golem's tmux session golem-N (idempotent — ignore-if-absent),
# so worktree teardown and session teardown are ONE step and finished golems
# don't linger in `tmux ls` / golem-status.sh after a merge+prune (#27).
# Refuses to remove a worktree with uncommitted changes (re-run after
# committing). The dirty check runs BEFORE any removal and classifies three
# ways — clean / dirty / unverifiable (#813) — so a probe that cannot run is
# never reported as dirtiness, and a refusal is always one the operator can
# still verify with their own `git status`. A worktree git no longer lists has
# nothing git-tracked left to lose, so its leftover directory is cleaned rather
# than skipped — tolerating, without a scary warning, the entries a bindfs/FUSE
# overlay refuses to release, and removing `.git` LAST so a partial removal stays
# recognizable as residue on a re-run (#834).
#
# Belt-and-suspenders: after teardown it repairs a polluted main-repo
# `core.worktree` (#258). An interrupted `git worktree remove --force` can leave
# the MAIN checkout's .git/config with a stale `core.worktree` pointing at the
# just-removed worktree, which silently breaks it — `git status` shows the whole
# tree as deleted and `git rev-parse --is-inside-work-tree` returns false. No
# script legitimately sets `core.worktree` on the main config, so one pointing at
# a non-existent path is unambiguous corruption and is safe to unset.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
#
# NOTE: the containers recipe also refreshed a bare host's on-disk runtime
# copies (.claude/hooks, justfile, bin) from origin/main after teardown — that
# was specific to the containers repo's bare-host golem layout and its
# bin/sync-host.sh, so it is intentionally NOT carried into this portable
# script.
#
# Usage: worktree-rm.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# Scrub git's hook-exported environment process-wide (#328). repo_root()
# (config.sh) already scrubs its OWN rev-parse subshell (#279), but this script
# then runs its own git MUTATIONS below (worktree remove / branch -D /
# config --unset core.worktree / worktree prune); a tainted GIT_DIR/GIT_COMMON_DIR
# forwarded from a git hook would redirect those to an OUTER repo — deleting a
# branch or unsetting core.worktree in the wrong checkout. `cd "$root"` does not
# re-anchor git while GIT_DIR is set, so unset the whole set here, before
# repo_root() and every other git call. Deliberately NO `|| true`: a readonly
# GIT_DIR makes `unset` fail, which under `set -e` aborts LOUDLY before any
# mutation — the fail-loud outcome, never a silent wrong-repo write. Uses
# config.sh's shared _git_env_scrub_names (#356 / #355) so the scrub set — static
# vars PLUS the dynamic GIT_CONFIG_KEY_<n>/VALUE_<n> pairs — stays in lockstep
# with repo_root()'s and worktree-new.sh's, one source of truth.
# shellcheck disable=SC2046  # intentional word-split: unset each scrub var by name
unset $(_git_env_scrub_names)

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "worktree-rm: N must be an issue number, got '$N'" >&2
    exit 2
fi

# symlink_is_false_dirty <worktree> <path> — true when <path> is a SYMLINK that
# git reports modified but whose target is byte-identical to the index (#768).
#
# On a macOS Docker bind mount (virtiofs/bindfs) a committed symlink can report
# stale stat attributes — `nlink=0 size=0`. `size=0` defeats git's stat
# comparison, so git marks the link `M` unconditionally and the dirty gate below
# reads it as uncommitted work that does not exist. Since #662/#665 (correctly)
# deny a main-session `git worktree remove --force` against a linked worktree,
# and this script is the sanctioned alternative, the false positive leaves NO
# working teardown path at all. Observed on .worktrees/issue-760 (AGENTS.md ->
# CLAUDE.md, .codegraph -> /cache/codegraph).
#
# The condition cannot be cleaned up from inside the worktree — `ln -sfn` clears
# it for minutes at most, and `git update-index --really-refresh` just prints
# `needs update` — so it has to be DISTINGUISHED here.
#
# READLINK-VS-INDEX IS THE LOAD-BEARING TEST; the mode check alone is a
# TAUTOLOGY. It is tempting to key off `git diff --raw` showing an unchanged
# `120000` mode and an all-zero destination hash, but a symlink whose target
# GENUINELY changed produces exactly that same shape:
#
#   :120000 120000 4cbb553 0000000 M   link.md    <- target really changed
#   :120000 120000 681311e 0000000 M   AGENTS.md  <- stale attrs, target identical
#
# The destination hash is all-zero in BOTH cases (git stages no blob for an
# unstaged change either way), so a check written against mode+hash would wave
# through every modified symlink and silently discard real work. Only comparing
# the on-disk target to the INDEX BLOB separates them. The mode test is kept
# purely as a cheap gate confirming we are looking at a symlink pair at all.
#
# FAIL-CLOSED everywhere: an unreadable blob, a missing file, a non-symlink, or
# any unexpected `--raw` shape returns non-zero, so teardown REFUSES rather than
# forcing past something it did not understand. A symlink whose target actually
# differs is real work and must still block.
#
# MUTATION-VERIFIED. Neutering the readlink comparison must turn the
# retargeted-symlink test red, and dropping the residue filter must turn the
# dirty-regular-file test red; both confirmed. The first mutation initially
# SURVIVED, and the reason is worth recording: the retarget fixture pointed the
# link at an UNCOMMITTED file, so `?? OTHER.md` kept the residue non-empty by
# itself and the refusal never depended on the symlink check at all — the fixture
# both armed and satisfied the gate. With the readlink test neutered and the
# destination committed, a genuinely retargeted symlink WAS silently discarded.
# The `src_mode` gate below is unreachable from this script's own call path (a
# type change is ` T `, and only ` M ` lines are routed here) and is kept as
# defensive depth for any future caller, not claimed as tested.
#
# Pure bash-3.2 + coreutils; no GNU-only regex (BSD `grep`/`sed` read `\s`/`\|`
# as literals, per project convention).
symlink_is_false_dirty() {
    local wtdir="$1" path="$2" raw src_mode dst_mode blob idx target

    # A symlink must still BE a symlink on disk; a delete or a replace-with-file
    # is real work.
    [ -L "$wtdir/$path" ] || return 1

    raw="$(command git -C "$wtdir" diff --raw -- "$path" 2>/dev/null || true)"
    [ -n "$raw" ] || return 1

    # `:<srcmode> <dstmode> <srcblob> <dstblob> <status>\t<path>`
    src_mode="$(command printf '%s' "$raw" | command awk '{print $1}')"
    src_mode="${src_mode#:}"
    dst_mode="$(command printf '%s' "$raw" | command awk '{print $2}')"
    blob="$(command printf '%s' "$raw" | command awk '{print $3}')"

    # Both sides must be symlink mode — a type change (link -> regular file)
    # is real work.
    [ "$src_mode" = "120000" ] || return 1
    [ "$dst_mode" = "120000" ] || return 1
    [ -n "$blob" ] || return 1

    # An all-zero source blob means git has no indexed content to compare
    # against; treat as real work rather than guessing.
    case "$blob" in *[!0]*) ;; *) return 1 ;; esac

    idx="$(command git -C "$wtdir" cat-file -p "$blob" 2>/dev/null)" || return 1
    target="$(command readlink "$wtdir/$path" 2>/dev/null)" || return 1

    # THE test: the indexed link target and the on-disk one must match exactly.
    [ "$idx" = "$target" ]
}

# worktree_dirty_state <worktree> — classify a worktree as exactly one of
# `clean` / `dirty` / `unverifiable`, echoed on stdout (#813).
#
# The two-way "empty status means clean" read this replaces produced a FALSE
# `has uncommitted changes` on a demonstrably clean tree, and did it in the most
# dangerous direction: the message names the one condition that makes an
# operator reach for `--force`, in precisely the situation where the claim can no
# longer be verified (status does not run anymore). A guard that cannot evaluate
# its condition must say THAT, never the alarming branch.
#
# Two pathologies converged on that message, both reproduced on git 2.55.0:
#
#   probe cannot run       dangling .git -> `fatal: not a git repository: (null)`
#                          -> `2>/dev/null || true` maps it to EMPTY -> empty
#                          reads as clean -> the `&&` force-remove then fails
#                          `not a working tree` -> the else-arm prints the lie.
#   probe answers about
#   the WRONG repo         with the .git file gone, git walks UP and resolves the
#                          MAIN checkout; the naive probe returned `?? .worktrees/`
#                          — main's untracked files reported as this worktree's
#                          uncommitted work. Worse than the first: it is non-empty,
#                          so it refuses "legitimately" while describing another tree.
#
# Hence TWO guards before the status call, not one:
#
#   1. `rev-parse --show-toplevel` must SUCCEED. A dangling or missing .git fails
#      here loudly instead of yielding a misread empty string.
#   2. The resolved toplevel must BE this worktree. That is what stops the
#      walk-up; guard 1 alone passes happily while answering about the parent.
#      Both sides go through `pwd -P` so a symlinked path compares equal rather
#      than reporting a spurious mismatch.
#
# The status exit code is then CHECKED rather than `|| true`-swallowed, so a
# status that fails for any other reason lands on `unverifiable` too.
#
# `git worktree repair` is NOT attempted: it cannot recover this state
# (`unable to locate repository; .git file does not reference a repository`,
# verified). Recovery is unavailable, which is exactly why the caller must run
# this check BEFORE the removal that deregisters the worktree.
#
# Pure: no mutations, no globals, verdict on stdout only — so the tests can
# slice it out and drive all three branches directly, the same shape as
# tmux_kill_outcome below.
#
# MUTATION-VERIFIED, and the coverage split is worth stating so a later reader
# does not mistake it for a gap. Neutering EITHER guard — the toplevel anchor,
# or `rev-parse` failing through as `clean` — turns the sliced classifier test
# red, and ONLY that test. The two end-to-end tests survive both mutations
# because they exercise the already-deregistered path, where git no longer
# lists the worktree and this function is never consulted. So the guards are
# pinned at the unit level and the leftover-directory path is pinned end-to-end;
# reverting the check/mutate ORDER turns the reorder test red plus eight of the
# #768/#325 tests, and dropping the leftover cleanup turns both end-to-end #813
# tests red.
worktree_dirty_state() {
    local wtdir="$1" top wt_real top_real out rc=0

    top="$(command git -C "$wtdir" rev-parse --show-toplevel 2>/dev/null)" || {
        command echo "unverifiable"
        return 0
    }
    [ -n "$top" ] || {
        command echo "unverifiable"
        return 0
    }

    wt_real="$(cd "$wtdir" 2>/dev/null && command pwd -P)" || wt_real=""
    top_real="$(cd "$top" 2>/dev/null && command pwd -P)" || top_real=""
    if [ -z "$wt_real" ] || [ -z "$top_real" ] || [ "$wt_real" != "$top_real" ]; then
        command echo "unverifiable"
        return 0
    fi

    out="$(command git -C "$wtdir" -c core.quotePath=false \
        status --porcelain --ignore-submodules=all 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        command echo "unverifiable"
        return 0
    fi

    if [ -n "$out" ]; then
        command echo "dirty"
    else
        command echo "clean"
    fi
}

# filter_stale_symlinks <worktree> <status-output> — set the globals
# `filtered_residue` (the status lines representing REAL work) and `stale_links`
# (how many ` M <path>` lines were stale-attribute symlink artifacts, #768).
#
# Filtering the residue rather than short-circuiting on "all lines are symlinks"
# is load-bearing: a worktree with BOTH a stale symlink AND a dirty regular file
# keeps the regular file in the residue and is still refused, so a force can
# never silently discard real work.
#
# Results come back through GLOBALS, not stdout, on purpose. Echoing the residue
# would force the caller into `residue="$(filter_stale_symlinks …)"`, and a
# command substitution runs in a SUBSHELL — every `stale_links` increment would
# be discarded, silently reporting 0 stale links no matter how many were found
# (caught by the #768 disclosure tests, which assert the count reaches the
# operator). The `while` loop stays in the caller's shell for the same reason.
filter_stale_symlinks() {
    local wtdir="$1" status_out="$2" line
    filtered_residue=""
    stale_links=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Only an unstaged modification (` M path`) can be this artifact.
        # Staged/added/deleted states are real work by construction.
        case "$line" in
            " M "*)
                if symlink_is_false_dirty "$wtdir" "${line#???}"; then
                    stale_links=$((stale_links + 1))
                    continue
                fi
                ;;
        esac
        filtered_residue="$filtered_residue$line
"
    done <<EOF
$status_out
EOF
}

root="$(repo_root)"
cd "$root"
wt="$GOLEM_WORKTREE_DIR/issue-$N"
br="${GOLEM_BRANCH_PREFIX}${N}"
removed=0

listed=0
if command git worktree list --porcelain | command grep -qx "worktree $root/$wt"; then
    listed=1
fi

# CHECK BEFORE MUTATING (#813). A failing `git worktree remove` DEREGISTERS the
# worktree before it reports failure — verified on git 2.55.0: with directory
# deletion blocked, remove printed `failed to delete …: Permission denied`,
# exited 255, and .git/worktrees/issue-N was already gone. So the dirty check
# must run here, while the worktree is still registered and the probe still
# works; behind the removal it is aimed at something that no longer exists.
# Refusing at this point also leaves the operator's own `git status` working, so
# the claim in the refusal is verifiable — the whole point of the issue.
state=""
stale_links=0
if [ "$listed" -eq 1 ]; then
    state="$(worktree_dirty_state "$wt")"
    if [ "$state" = "dirty" ]; then
        # Re-read the status to get the LINES (the classifier returns only a
        # verdict). Deliberately NOT `|| true`: swallowing a failure here would
        # yield an empty `dirty`, an empty residue, and a fall-through to
        # `state="clean"` — re-creating this issue's exact bug (a probe that
        # could not run silently reading as clean) one layer down, and this time
        # ending in a force-remove rather than a false refusal. The classifier
        # just proved the status runs, so a failure now is a genuine anomaly:
        # fail closed.
        dirty_rc=0
        dirty="$(command git -C "$wt" -c core.quotePath=false \
            status --porcelain --ignore-submodules=all 2>/dev/null)" || dirty_rc=$?
        if [ "$dirty_rc" -ne 0 ]; then
            command echo "worktree-rm: cannot re-read the status of $wt to classify its changes." >&2
            command echo "  It was reported dirty a moment ago; refusing rather than forcing." >&2
            command echo "  Inspect: git -C $wt status" >&2
            exit 1
        fi
        # Distinguished from the failure above on purpose: here the re-read
        # SUCCEEDED and simply found nothing, meaning the tree changed between
        # the two probes. Refusing is still the safe call — something else is
        # writing to this worktree right now — but saying "cannot re-read" would
        # describe a failure that did not happen.
        if [ -z "$dirty" ]; then
            command echo "worktree-rm: $wt changed between two status checks." >&2
            command echo "  It read dirty, then clean; something else is writing to it." >&2
            command echo "  Refusing rather than racing — re-run once it settles." >&2
            exit 1
        fi
        filter_stale_symlinks "$wt" "$dirty"
        dirty="$filtered_residue"
        if [ -n "$dirty" ]; then
            command echo "worktree-rm: $wt has uncommitted changes." >&2
            command echo "  Re-run after committing, or inspect with: git -C $wt status" >&2
            exit 1
        fi
        # Only stale symlink artifacts remained — treat as clean and carry the
        # count through to the force-remove message below.
        state="clean"
    fi
fi

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

# remove_leftover_dir <worktree> — delete a deregistered worktree's leftover
# directory, tolerating the entries a bindfs/FUSE overlay will not let go (#834).
#
# TWO DIFFERENT ISSUES MEET AT THIS LINE, and conflating them loses one:
# #813 is about never MISREPORTING dirtiness — a probe that cannot run must not
# be reported as uncommitted work. This is about FILESYSTEM TOLERANCE during the
# removal itself: the classification was already correct and the removal was
# already authorized; the filesystem simply refuses part of it.
#
# On the documented macOS/VirtioFS `bindfs` overlay, stale dentries whose inodes
# are gone return EBADF from `unlink`/`stat` while still appearing in `readdir`
# (~3,700 `target/debug/incremental/*.o` files in the #813 report). No
# unprivileged call clears them, and nothing is at risk: git has no record of
# those files, `.worktrees/` is gitignored, and the golem collision guard reads
# `git worktree list`, not the directory. So a residual directory is an EXPECTED
# outcome on that platform, not a fault — and teardown runs unattended, where a
# `WARNING` costs an operator an adjudication for a condition that is both
# expected and harmless.
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
remove_leftover_dir() {
    local wtdir="$1" survivors

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
    else
        command echo "  cleared leftover directory $wtdir ($survivors entries could not be removed)"
    fi
    command echo "  (expected on a bindfs/FUSE overlay — nothing git-tracked is at risk)"
    removed=1
}

# A worktree git no longer lists cannot hold unmerged commits to lose, so there
# is nothing git-tracked left to protect — but the directory may still be on
# disk. Before this fix the whole removal block was gated on being listed, so
# such a leftover was NEVER cleaned: re-running worktree-rm.sh reported "nothing
# to remove" while the directory sat there, which is why the #813 reporter had to
# `rm -rf` by hand. Clean it up and prune, then continue to branch/tmux teardown
# — but only once the guard above confirms it really is worktree residue.
if [ "$listed" -eq 0 ] && { [ -e "$wt" ] || [ -L "$wt" ]; }; then
    residue_reason="$(leftover_is_worktree_residue "$root" "$wt")" || true
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
                command echo "worktree-rm: $wt is a symlink, not a worktree directory." >&2
                command echo "  Teardown never deletes through a symlink." >&2
                ;;
            outside-root)
                command echo "worktree-rm: $wt resolves outside the repo root ($root)." >&2
                command echo "  Check GOLEM_WORKTREE_DIR — teardown only removes paths inside the repo." >&2
                ;;
            no-fingerprint)
                command echo "worktree-rm: $wt has no .git entry, so it may never have been a worktree." >&2
                command echo "  It is not registered either, so there is nothing to confirm it is stale residue." >&2
                ;;
            *)
                command echo "worktree-rm: $wt could not be resolved for the residue check." >&2
                ;;
        esac
        command echo "  Refusing to delete it — inspect and remove by hand if it is stale." >&2
        exit 1
    fi
fi

# The condition here is `-e` alone while the refusal above is `-e || -L`, and
# the asymmetry is deliberate: a symlink (dangling or not) can never reach this
# point, because leftover_is_worktree_residue refuses every symlink and the
# block above exits on that refusal. Widening this one to match would therefore
# change nothing today — but it would quietly become the branch that `rm -rf`s a
# symlink if that guard were ever relaxed, so it stays narrow on purpose.
if [ "$listed" -eq 0 ] && [ -e "$wt" ]; then
    command echo "worktree-rm: $wt is no longer registered as a worktree" >&2
    command echo "  (nothing git-tracked left to lose) — removing the leftover directory" >&2
    remove_leftover_dir "$wt"
    command git worktree prune || true
fi

if [ "$listed" -eq 1 ]; then
    # The probe could not be evaluated, yet git still lists the worktree — a
    # genuinely unexplained state. Say THAT and fail closed; never claim
    # "uncommitted changes" for a condition the guard could not evaluate, and
    # never advertise a blind `--force` as the remedy (the issue's central
    # complaint: it is exactly what a careful operator must not run blind).
    if [ "$state" = "unverifiable" ]; then
        command echo "worktree-rm: cannot verify whether $wt has uncommitted changes." >&2
        command echo "  git could not resolve it as a work tree, but it is still registered." >&2
        command echo "  Inspect before removing anything: git -C $wt status; git worktree list" >&2
        exit 1
    fi
    # Capture the first attempt's stderr rather than discarding it. When this
    # removal fails it may ALSO have deregistered the worktree (#813), in which
    # case the force below can only report the CONSEQUENCE ("is not a working
    # tree") and this message holds the actual cause.
    first_err="$(command git worktree remove "$wt" 2>&1)" && first_rc=0 || first_rc=$?
    if [ "$first_rc" -eq 0 ]; then
        command echo "  removed worktree $wt"
        removed=1
    else
        # Plain `git worktree remove` refuses a worktree that contains a
        # POPULATED submodule ("working trees containing submodules cannot be
        # moved or removed") even when the submodule is clean — and
        # worktree-new.sh now populates submodules on creation (#325), so this
        # fires on ORDINARY teardown, not just on genuine uncommitted work.
        #
        # RE-VERIFY IMMEDIATELY BEFORE FORCING (#813 review cycle 5). The
        # up-front classification is what fixes this issue's ordering bug, but
        # it is NOT sufficient authority to force: the plain removal above can
        # fail precisely BECAUSE the tree became dirty after the classification,
        # and `git worktree remove` without `--force` refuses on uncommitted
        # changes. Trusting the older verdict there would silently discard work
        # that landed in the window — demonstrated, not theorized: with a writer
        # appending to a tracked file between the two steps, the old ordering
        # removed the worktree and destroyed the change.
        #
        # This restores the freshness the pre-#813 code had for free by reading
        # status inside this failure branch (the #325 gate: a worktree with BOTH
        # a dirty regular file AND a populated submodule prints the same
        # submodule message, so only an ignore-submodules status tells them
        # apart). #813 moved that read EARLIER so a deregistering failure could
        # not corrupt it; it must still also happen HERE, so the force is
        # authorized by the freshest possible read rather than a stale one.
        # The re-read goes through the SAME stale-symlink filter the up-front
        # check uses (#768). A stale-attr symlink reads `dirty` from the raw
        # classifier by construction — that is the false positive #768 exists to
        # absorb — so re-verifying with the bare classifier would refuse every
        # teardown on a macOS bind mount and re-create the deadlock #768 closed.
        # What must block here is REAL work: the residue after filtering.
        force_state="$(worktree_dirty_state "$wt")"
        if [ "$force_state" = "dirty" ]; then
            force_dirty_rc=0
            force_dirty="$(command git -C "$wt" -c core.quotePath=false \
                status --porcelain --ignore-submodules=all 2>/dev/null)" || force_dirty_rc=$?
            if [ "$force_dirty_rc" -ne 0 ]; then
                command echo "worktree-rm: cannot re-check $wt before forcing; refusing." >&2
                command echo "  Nothing was removed. Inspect: git -C $wt status" >&2
                exit 1
            fi
            filter_stale_symlinks "$wt" "$force_dirty"
            if [ -n "$filtered_residue" ]; then
                command echo "worktree-rm: $wt gained uncommitted changes after it was checked." >&2
                command echo "  Refusing to force past work that appeared in the meantime." >&2
                command echo "  Nothing was removed. Inspect: git -C $wt status" >&2
                exit 1
            fi
            # `filter_stale_symlinks` reset and recomputed `stale_links` here,
            # and the disclosure message below reads it. That is deliberate: the
            # count it reports now comes from the freshest read rather than the
            # up-front one, so the number matches the tree actually being
            # forced. (Pinned by the #768 "counts TWO stale symlinks" test,
            # which still passes through this path.)
            force_state="clean"
        fi
        if [ "$force_state" != "clean" ]; then
            command echo "worktree-rm: $wt could not be re-checked before forcing (it read $force_state)." >&2
            command echo "  Nothing was removed. Inspect: git -C $wt status" >&2
            exit 1
        fi
        rm_err="$(command git worktree remove --force "$wt" 2>&1)" && rm_rc=0 || rm_rc=$?
        if [ "$rm_rc" -eq 0 ]; then
            if [ "$stale_links" -gt 0 ]; then
                command echo "  removed worktree $wt (forced past $stale_links stale symlink attr(s))"
            else
                command echo "  removed worktree $wt (forced past clean submodules)"
            fi
            removed=1
        else
            # The tree was verified clean, so this is NOT uncommitted work — it
            # is a removal that failed for some other reason (an undeletable
            # path under a FUSE/bindfs overlay is the observed one). Report what
            # git actually said instead of the false dirtiness claim #813 was
            # filed about. Note git may ALREADY have deregistered the worktree
            # while failing, so a re-run takes the leftover-directory path above
            # rather than looping on this message.
            command echo "worktree-rm: could not remove $wt (the tree was verified clean)." >&2
            # Sanitized for the same reason the tmux failure text is: captured
            # subprocess stderr embeds PATHS, so a crafted filename could
            # otherwise smuggle ANSI escapes or a CR line-overwrite into the
            # operator's terminal.
            first_err_safe="$(sanitize_stderr "$first_err")"
            command echo "  git said: ${first_err_safe:-(no output)}" >&2
            # Only worth printing when it adds something: after a first attempt
            # that already deregistered the worktree, the force's message is the
            # downstream "is not a working tree", not the cause.
            if [ -n "$rm_err" ] && [ "$rm_err" != "$first_err" ]; then
                rm_err_safe="$(sanitize_stderr "$rm_err")"
                command echo "  then, with --force: ${rm_err_safe:-(unprintable)}" >&2
            fi
            exit 1
        fi
    fi
fi

if [ -n "$(command git branch --list "$br")" ]; then
    command git branch -D "$br"
    command echo "  deleted branch $br"
    removed=1
fi

# tmux_kill_outcome <rc> <stderr> — classify one `tmux kill-session` attempt as
# exactly one of `killed` / `absent` / `failed` (#533).
#
# `kill-session` returns the SAME non-zero exit for "there was no such session"
# (an expected no-op) and for a real fault — a wedged or unreachable server, a
# permission error — where the session is STILL ALIVE and the kill did not
# happen. Only the stderr text separates them, so it is classified rather than
# discarded.
#
# The benign set is wider than "session not found": tmux 3.5a emits three
# distinct shapes for "nothing to kill", and two never mention a session at all.
#
#   server up, session absent   can't find session: golem-N
#   no server ever started      error connecting to <sock> (No such file …)
#   server started then exited  no server running on <sock>
#
# Matching only the first would warn on every ordinary teardown on a host with
# no tmux server — noise operators would learn to ignore, defeating the warning.
#
# But `error connecting to` alone is TOO wide, and dangerously so: tmux formats
# it as `error connecting to <sock> (<strerror>)`, and only the ENOENT variant
# means "no server". The same prefix carries `(Permission denied)` for a LOCKED
# socket whose session is very much STILL RUNNING (verified: chmod 000 on a live
# socket yields exactly that message, and the session survives). Swallowing that
# would re-create this script's original bug under a new message, so the socket
# arm must ALSO see the no-such-file wording; anything else about connecting
# falls through to `failed`.
#
# That parenthetical is libc's `strerror`, which — unlike the three tmux-authored
# literals above — is TRANSLATED via LC_MESSAGES (glibc ships e.g. "Aucun fichier
# ou dossier de ce nom" for ENOENT). Under a non-English locale the substring
# would miss and every teardown on a server-less host would warn: exactly the
# noise this arm exists to prevent. The caller therefore pins LC_ALL=C on the
# tmux invocation so the text is guaranteed English; see the dispatch below.
#
# A crashed server leaving a STALE socket does NOT reach this arm at all —
# verified against tmux 3.5a with a bound, non-listening socket, which reports
# `no server running on <sock>` (already benign above) rather than ECONNREFUSED.
#
# Anything else, INCLUDING an empty stderr, is `failed`. A tmux that fails
# without saying why is exactly the unexplained case an operator needs to see;
# defaulting the unknown to benign would re-create the swallowed-error bug.
#
# Pure: no I/O beyond the verdict, no globals, no side effects — so the tests
# can slice it out and drive every branch directly. `rc` is compared as a
# STRING so a non-numeric argument yields `failed` rather than aborting on an
# arithmetic error. Lowercased with `tr`, not `${v,,}` (bash-4, banned by
# tests/lint-shell-portability.sh).
tmux_kill_outcome() {
    local rc="$1" err="$2" low
    if [ "$rc" = "0" ]; then
        command echo "killed"
        return 0
    fi
    # Fall back to the RAW text if `tr` is unavailable: an empty `low` would send
    # every message — including the benign ones — down the `failed` arm, warning
    # on ordinary teardowns. tmux's own wording is already lowercase so those
    # still match; what degrades is case-insensitivity, which costs only the
    # ENOENT variant (libc capitalizes "No such file or directory"). That lands
    # on `failed` — a spurious warning rather than a swallowed failure, i.e. the
    # safe direction. `|| true` keeps set -e from aborting teardown here (same
    # guard as the sanitizer below).
    low="$(command printf '%s' "$err" | command tr '[:upper:]' '[:lower:]' || true)"
    low="${low:-$err}"
    case "$low" in
        *"can't find session"* | *"session not found"* | \
            *"no server running"* | \
            *"error connecting to"*"no such file"*)
            command echo "absent"
            ;;
        *)
            command echo "failed"
            ;;
    esac
}

# Kill the golem's tmux session so a finished golem does not linger in
# `tmux ls` / golem-status.sh after merge+prune (#27). Idempotent and
# ignore-if-absent: a missing session (or no tmux at all) is a clean no-op.
#
# Kill UNCONDITIONALLY rather than has-session-then-kill (#486): the old guard
# `tmux has-session -t "$sess"` raced the golem's own `claude … ; claude …`
# self-teardown and intermittently reported the session absent while it lingered
# a beat longer, so the kill was skipped and the session leaked. `kill-session`
# is the very operation the guard protected and is already a safe no-op on a
# missing session, so dropping the pre-check removes the race with no downside.
# `-t "=$sess"` forces exact-name matching (the `=` prefix) instead of tmux's
# prefix/fnmatch target matching. The echo + `removed=1` fire only when a session
# was actually killed, preserving the contract that the line prints on a real
# kill.
#
# stderr is CAPTURED rather than sent to /dev/null (#533) so tmux_kill_outcome
# can tell an absent session from a real failure. On `failed` we warn and carry
# on: `removed` deliberately stays 0 — nothing was removed, and setting it would
# fire the terminal `reaped` feed event (#446) for a golem whose session is still
# alive, telling golem-status.sh the opposite of the truth. Nor does it abort:
# teardown is already past the destructive git mutations, so failing here would
# strand a removed worktree behind a non-zero exit. The `*)` arm is reserved for
# an internal-contract violation — never a duplicate of a real outcome, so a
# future typo in the helper cannot masquerade as one (#542).
sess="golem-$N"
if command -v tmux >/dev/null 2>&1; then
    # LC_ALL=C so the `(<strerror>)` parenthetical tmux appends to a connect
    # failure is guaranteed English — it is libc-translated, and the classifier's
    # no-such-file match would miss under a non-English locale, warning on every
    # server-less teardown. Scoped to this one call, not exported.
    tmux_rc=0
    tmux_err="$(LC_ALL=C tmux kill-session -t "=$sess" 2>&1)" || tmux_rc=$?
    case "$(tmux_kill_outcome "$tmux_rc" "$tmux_err")" in
        killed)
            command echo "  killed tmux session $sess"
            removed=1
            ;;
        absent) ;;
        failed)
            # `${tmux_err:-…}` because an EMPTY stderr is itself a `failed` case
            # (an unexplained non-zero is the one an operator most needs to see);
            # interpolating it raw ended the line at a dangling `): `. Control
            # characters are stripped: this text is now echoed to a terminal
            # rather than discarded, and it embeds the socket path, so a crafted
            # path or a spoofed tmux earlier on PATH could otherwise smuggle ANSI
            # escapes into the operator's session. The class drops every C0
            # control plus DEL (\177), deliberately KEEPING only tab (\011) and
            # newline (\012) so a genuine multi-line tmux error stays legible —
            # which is why this is not simply `[:cntrl:]`, a class that would eat
            # both. Octal ranges rather than named classes so GNU and BSD `tr`
            # agree. `printf '%s'` keeps the format string fixed, so stderr
            # containing a literal `%s` or a backslash is data, never format.
            #
            # `\013-\037` is ONE range on purpose. Enumerating it as
            # `\013\014\016-\037` silently skipped \015 (CR), which a terminal
            # renders by returning the cursor to column 0 — letting crafted
            # stderr overwrite the WARNING text and make the line read as
            # something else entirely. That is line-overwrite spoofing, the same
            # class as the ANSI escapes this strip exists to stop, so the range
            # is kept contiguous rather than spelled out byte by byte.
            #
            # The C1 range (\200-\237, 8-bit CSI/OSC) is deliberately NOT stripped.
            # Those byte values are also UTF-8 CONTINUATION bytes, so deleting
            # them corrupts any multibyte character in a socket path — U+011B is
            # `c4 9b`, and stripping the `9b` leaves an invalid lone `c4` that
            # renders as mojibake. That would break legitimate non-ASCII paths in
            # exchange for defending a form most terminals ignore by default.
            # Residual risk accepted, and stated here so it is a decision rather
            # than an oversight.
            # `|| true` because a bare assignment from a command substitution IS
            # subject to `set -e`: were `tr` unavailable, the script would abort
            # at 127 here — AFTER the destructive git mutations, stranding a
            # removed worktree behind a non-zero exit. This warning is
            # best-effort diagnostics and must never be the thing that fails
            # teardown, the same reasoning as the `|| true` on the reaped hook
            # below. The `:-` fallback then covers the empty result.
            # Three distinguishable states, not two: tmux said nothing; tmux said
            # something printable; or tmux said something that survived sanitizing
            # as nothing (an all-control payload, or a `tr` that could not run).
            # The third is the most suspicious and most actionable, so it gets its
            # own wording rather than being folded into the boring default.
            if [ -z "$tmux_err" ]; then
                tmux_err_safe="(no stderr from tmux)"
            else
                tmux_err_safe="$(command printf '%s' "$tmux_err" |
                    command tr -d '\000-\010\013-\037\177' || true)"
                tmux_err_safe="${tmux_err_safe:-(stderr present but unprintable)}"
            fi
            command echo "worktree-rm: WARNING: tmux kill-session failed for $sess" \
                "(session may still be running): $tmux_err_safe" >&2
            ;;
        *)
            command echo "worktree-rm: ERROR: internal — tmux_kill_outcome returned an unknown outcome" >&2
            ;;
    esac
fi

# Repair a polluted main-repo core.worktree (#258). An interrupted
# `git worktree remove --force` can leave the MAIN config with a stale
# core.worktree pointing at a now-deleted path, which makes the whole checkout
# look deleted (git status = all D, rev-parse --is-inside-work-tree = false).
# Only unset it when it points at a path that no longer exists — a legit,
# existing core.worktree is left untouched. `cd "$root"` above put us in the main
# checkout, so `git config` reads/writes the main config.
stale_wt="$(command git config --get core.worktree 2>/dev/null || true)"
if [ -n "$stale_wt" ] && [ ! -e "$stale_wt" ]; then
    command git config --unset core.worktree || true
    command git worktree prune || true
    command echo "  repaired stale core.worktree ($stale_wt no longer exists)"
    removed=1
    if [ "$(command git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
        command echo "worktree-rm: WARNING: main checkout still not a work tree after core.worktree repair" >&2
    fi
fi

# Emit a terminal `reaped` feed event so a golem torn down here does not linger
# on golem-status.sh's BLOCKED list (#446). Teardown otherwise leaves the golem's
# last `gate` line as its most-recent feed entry, so the reader keeps rendering
# it BLOCKED for the whole GOLEM_BLOCK_TTL window even though its PR merged and
# its session is gone (the `golem-743` ghost in the issue). A `REAPED:`-prefixed
# Notification classifies as the `reaped` kind, which — like `idle`/`resolved` —
# is NOT in the BLOCKED set, so as the golem's most-recent line it supersedes the
# stale gate on the next sweep. Only when something was actually removed
# (`removed=1`): a no-op teardown had no live golem to reap.
#
# GOLEM_ID=golem-$N is forced for the same reason golem-resolve.sh forces it:
# this script runs in the MAIN checkout (`cd "$root"` above), so the hook's
# git-worktree-basename fallback would resolve to the main repo and stamp
# `golem-?`, never correlating to the reaped golem. Best-effort and never fails
# teardown — the hook always exits 0, and `|| true` keeps `set -e` from aborting
# over a missing hook / absent jq.
if [ "$removed" -eq 1 ]; then
    notify_hook="$SCRIPT_DIR/../hooks/golem-notify.sh"
    if [ -x "$notify_hook" ]; then
        msg="REAPED: worktree/session for golem-$N torn down"
        if command -v jq >/dev/null 2>&1; then
            reaped_payload="$(jq -cn --arg m "$msg" '{message: $m}')"
        else
            reaped_payload="$(command printf '{"message":"%s"}' "$msg")"
        fi
        command printf '%s' "$reaped_payload" | GOLEM_ID="golem-$N" "$notify_hook" || true
    fi
fi

if [ "$removed" -eq 0 ]; then
    command echo "worktree-rm: nothing to remove for issue $N ($wt / $br / $sess absent)"
fi
