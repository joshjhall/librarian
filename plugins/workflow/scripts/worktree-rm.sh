#!/usr/bin/env bash
# worktree-rm.sh — post-merge cleanup: remove a worktree and its branch
# (clean no-op if absent).
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
# than skipped — tolerating, without a scary warning, the entries the macOS
# virtiofs mount stack refuses to release, and removing `.git` LAST so a partial
# removal stays recognizable as residue on a re-run (#834). When those entries
# make the directory undeletable, the `issue-N` PATH is still freed by renaming
# the tree aside to a `.wedged-*` sibling (#936) — the path is what callers
# need, and a rename succeeds where unlinking the contents cannot.
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
#   GOLEM_UV_CACHE_DIR (/cache/venv) — the per-issue venv removed on teardown
#   GOLEM_POST_REMOVE_HOOK ("") / GOLEM_POST_REMOVE_HOOK_TIMEOUT (300) — below
#   GOLEM_RENAME_TIMEOUT (30) — bounds each rename-aside of a wedged leftover
#
# POST-REMOVE HOOK (#1092) — the one extension point for a CONSUMER repo. A repo
# that keeps per-checkout artifacts OFF the worktree (venvs, `target/`, CMake
# trees, `node_modules` under /cache/<kind>/<project>--<worktree-dir>, as
# containers#1005 does) would orphan them on every teardown, and golem Phase D,
# `--teardown` and orchestrate all call THIS script directly — so a recipe-tail
# prune in the consumer's own justfile is skipped by every automated path.
#   Which:  $GOLEM_POST_REMOVE_HOOK if set, else <main-checkout>/.golem/post-remove
#           if present. A named hook that is not an executable file WARNS.
#   When:   once, only after something was actually torn down. Every refusal
#           (dirty / unverifiable / residue / outside the repo) exits before it,
#           and a no-op teardown ("nothing to remove") does not run it.
#   Args:   $1 issue number or worktree name (`issue-42` normalized to `42`)
#           $2 main-checkout root (absolute; also the hook's cwd)
#           $3 the removed worktree's absolute path (may no longer exist)
#           env GOLEM_WORKTREE_MODE=issue|name
#   How:    non-interactive (stdin is /dev/null) and bounded to
#           GOLEM_POST_REMOVE_HOOK_TIMEOUT seconds. Best-effort: a non-zero exit
#           or a timeout is a WARNING on stderr, never a failed teardown. Where
#           bounded_run cannot bound (no sleep/mktemp/cat) the hook still runs,
#           UNBOUNDED, after a warning — it is never skipped.
#   Trust:  the repo-local hook is EXECUTED with the caller's environment, so
#           the main checkout's working tree is trusted exactly as its justfile
#           or git hooks are. Do not tear down from a checkout of untrusted refs.
#
# NOTE: the containers recipe also refreshed a bare host's on-disk runtime
# copies (.claude/hooks, justfile, bin) from origin/main after teardown — that
# was specific to the containers repo's bare-host golem layout and its
# bin/sync-host.sh, so it is intentionally NOT carried into this portable
# script.
#
# Accepts EITHER an issue number (the original contract) OR a bare worktree
# name (#1005) — `worktree-rm.sh okf-probe`. A name-mode teardown resolves its
# branch from `git worktree list` rather than the prefix convention, and deletes
# that branch only when it is merged into GOLEM_BASE_REF. Every refusal above is
# shared verbatim by both modes, so the name path is not a #662 bypass.
#
# Usage: worktree-rm.sh <issue-number|worktree-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=./bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"
# shellcheck source=./worktree-rm-leftover.sh
. "$SCRIPT_DIR/worktree-rm-leftover.sh"
# shellcheck source=./cache-entry.sh
. "$SCRIPT_DIR/cache-entry.sh"

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

# TWO MODES, ONE SAFETY PATH (#1005). The argument is either an ISSUE NUMBER
# (the original contract, byte-identical behavior) or a bare WORKTREE NAME.
#
# Why a name mode exists at all: before it, a worktree created under any other
# name had NO supported teardown path. `worktree-rm.sh okf-probe` refused as a
# non-number, and the raw `git worktree remove --force` that would otherwise
# clean it up is DENIED by the #662 bash-guard from the main session. Both
# refusals are correct in isolation; together they left no door, and the litter
# (a directory plus a branch no cleanup path would ever delete) was removable by
# neither the golem that made it nor the orchestrator.
#
# NOT fixed on the creation side instead. The issue weighs "refuse to create a
# worktree whose name cannot later be removed" heavily, but worktree-new.sh
# ALREADY enforces exactly that with this same `^[0-9]+$` test — the observed
# worktree came from a raw `git worktree add`, which that script never saw.
# Hardening a create path that was not used closes nothing.
#
# The modes differ ONLY in how `wt` / `br` / `sess` are derived; they converge
# before the first probe, so the dirty check, the stale-symlink filter, the
# residue guard, the pre-force re-check and the core.worktree repair are shared
# VERBATIM rather than re-stated. The safety property is preserved by reusing the
# code, which is why this is not a #662 bypass.
#
# ONE PATH SEGMENT, never a path. `[A-Za-z0-9._-]+` admits no `/`, so the
# argument cannot escape GOLEM_WORKTREE_DIR — the containment
# leftover_is_worktree_residue enforces downstream is also enforced at the front
# door, where the bad input can still be named in an error. `.` and `..` match
# that class and are excluded explicitly: `$GOLEM_WORKTREE_DIR/..` is the repo
# root itself and `$GOLEM_WORKTREE_DIR/.` the worktree dir, so either would aim
# the whole teardown at a directory full of real work.
N="${1:-}"
case "$N" in
    "" | "." | "..")
        command echo "worktree-rm: need an issue number or a worktree name, got '$N'" >&2
        exit 2
        ;;
esac
if [[ "$N" =~ ^[0-9]+$ ]]; then
    wt_mode="issue"
elif [[ "$N" =~ ^issue-[0-9]+$ ]]; then
    # THE DIRECTORY-NAME SPELLING IS ISSUE MODE, NOT A NAME (#1005 review).
    # `issue-42` is what `ls .worktrees/` prints, so it is the spelling an
    # operator most naturally reaches for — and as a bare name it matched the
    # name arm below, where `wt` happens to resolve to the SAME directory. That
    # coincidence is what made it dangerous: teardown appeared to work while
    # three things silently diverged. `sess` became `golem-issue-42` instead of
    # `golem-42`, so the real tmux session was never killed (defeating this
    # script's own stated purpose); the `REAPED:` event was stamped with the
    # wrong GOLEM_ID, so golem-status.sh never cleared the row; and branch
    # teardown took the name-mode merge gate, which KEEPS a squash-merged golem
    # branch — the exact case the issue-mode unconditional delete exists to
    # handle. Reproduced on git 2.55.0: `worktree-rm.sh issue-42` printed "kept
    # branch feature/issue-42 — it is NOT merged" on an ordinary teardown.
    # Normalizing to the number routes every derivation through issue mode.
    N="${N#issue-}"
    wt_mode="issue"
elif [[ "$N" =~ ^[A-Za-z0-9._-]+$ ]]; then
    wt_mode="name"
else
    command echo "worktree-rm: '$N' is neither an issue number nor a worktree name." >&2
    command echo "  A name is one path segment of [A-Za-z0-9._-] — no '/', so teardown" >&2
    command echo "  cannot be aimed outside the worktree directory." >&2
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

# resolve_worktree_branch <porcelain> <abs-worktree-path> — echo the branch a
# registered worktree has checked out, or nothing (#1005).
#
# Name mode CANNOT derive the branch the way issue mode does. Issue mode owns
# both ends of the naming convention — worktree-new.sh created `issue-N` on
# `${GOLEM_BRANCH_PREFIX}N`, so the branch is a pure function of the argument. A
# scratch worktree was created by whatever made it: the observed one is
# `okf-probe` on `tmp/okf-probe-890`, where no prefix rule connects the two.
# Guessing `${GOLEM_BRANCH_PREFIX}okf-probe` would name a branch that does not
# exist, and the teardown would silently leave the real one behind — precisely
# the "a branch no cleanup path will ever delete" half of this issue.
#
# So the branch is READ from git's own registration. `git worktree list
# --porcelain` emits stanzas separated by a blank line:
#
#     worktree /abs/path
#     HEAD <sha>
#     branch refs/heads/tmp/okf-probe-890   <- absent when HEAD is detached
#
# Only the `branch` line INSIDE the matching stanza counts, hence the `in_stanza`
# latch: a flat `grep` for `branch ` would return whichever worktree happened to
# be listed first. A branch name may itself contain `/` (`tmp/okf-probe-890`), so
# the prefix is stripped with `${v#refs/heads/}` rather than by taking a last
# path component.
#
# Echoes NOTHING for a detached HEAD, an unregistered leftover directory, or an
# unmatched path. That is a clean no-op, not an error: those states have no
# branch to delete, and the caller's `git branch --list` guard already treats an
# empty name as nothing to do.
#
# Parsed in pure bash (no `grep`/`sed`) per project convention — this is the
# simple-format case read_yaml_list is the worked example for, and it sidesteps
# both the BSD-regex split and the #928 `grep -q` SIGPIPE inversion outright.
resolve_worktree_branch() {
    local porcelain="$1" want="$2" line in_stanza=0
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                if [ "${line#worktree }" = "$want" ]; then
                    in_stanza=1
                else
                    in_stanza=0
                fi
                ;;
            "branch refs/heads/"*)
                if [ "$in_stanza" -eq 1 ]; then
                    command echo "${line#branch refs/heads/}"
                    return 0
                fi
                ;;
        esac
    done <<EOF
$porcelain
EOF
    return 0
}

root="$(repo_root)"
cd "$root"
if [ "$wt_mode" = "issue" ]; then
    wt="$GOLEM_WORKTREE_DIR/issue-$N"
    br="${GOLEM_BRANCH_PREFIX}${N}"
else
    wt="$GOLEM_WORKTREE_DIR/$N"
    br="" # resolved from git's registration once the porcelain is captured
fi
removed=0

listed=0
# Both properties at once, rather than trading one for the other (#928 review).
# `git worktree list` failing must NOT read as "already gone" — a broken repo
# would then be reported as a successful removal. But keeping the PIPE to
# preserve git's exit status also keeps the #928 SIGPIPE inversion: a genuine
# match makes `grep -q` exit first, git dies 141, and pipefail flips "IS listed"
# to listed=0 — feeding the CHECK-BEFORE-MUTATING guard below a false negative.
# Capture first: the here-string leaves no writer to signal. The `set -e` half is
# MEASURED (git 2.55.0, corrupted .git/HEAD): capture exits 128, the old piped
# form exits 0 and reports the worktree absent. Unguarded by a test for the
# reason recorded in worktree-new.sh.
wt_list="$(command git worktree list --porcelain)"
if command grep -Fqx -- "worktree $root/$wt" <<<"$wt_list"; then
    listed=1
fi

# Name mode resolves its branch from the porcelain just captured, rather than
# calling `git worktree list` a second time (#1005). Re-running it would read a
# DIFFERENT moment than the `listed` check above, so a concurrent teardown could
# leave this script believing the worktree is registered while its branch lookup
# saw it gone. One capture, both answers.
if [ "$wt_mode" = "name" ] && [ "$listed" -eq 1 ]; then
    br="$(resolve_worktree_branch "$wt_list" "$root/$wt")"
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

# A worktree git no longer lists cannot hold unmerged commits to lose, so there
# is nothing git-tracked left to protect — but the directory may still be on
# disk. Before this fix the whole removal block was gated on being listed, so
# such a leftover was NEVER cleaned: re-running worktree-rm.sh reported "nothing
# to remove" while the directory sat there, which is why the #813 reporter had to
# `rm -rf` by hand. Clean it up and prune, then continue to branch/tmux teardown
# — but only once the guard confirms it really is worktree residue.
if [ "$listed" -eq 0 ] && { [ -e "$wt" ] || [ -L "$wt" ]; }; then
    cleanup_leftover_dir "$root" "$wt" \
        "worktree-rm: $wt is no longer registered as a worktree
  (nothing git-tracked left to lose) — removing the leftover directory"
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
            # Never FORCE on an unevaluable read — but do not stop there either
            # (#1088). The usual reason the re-check cannot resolve the tree is
            # that the plain removal above DEREGISTERED it before failing on an
            # undeletable entry, so `git -C $wt` no longer sees a work tree.
            # Refusing with "Nothing was removed" was then false on both
            # counts: the registration was gone and the directory half-emptied,
            # with the branch and tmux session left behind. Hand the decision to
            # the same registration re-read the force failure uses — it refuses
            # only while git still lists the path (or the list is unreadable).
            command echo "worktree-rm: $wt could not be re-checked before forcing (it read $force_state)." >&2
            first_err_safe="$(sanitize_stderr "$first_err")"
            command echo "  git said: ${first_err_safe:-(no output)}" >&2
            adopt_if_deregistered "  The worktree WAS deregistered by the first removal attempt, and the
  remnant holds nothing git-tracked — completing the teardown now."
        else
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
                # path is the observed one — see remove_leftover_dir's header for
                # the platforms and why virtiofs, not the overlay above it). Report
                # what git actually said instead of the false dirtiness claim #813
                # was filed about.
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

                adopt_if_deregistered "  The worktree WAS deregistered by the failed removal, and the remnant
  holds nothing git-tracked — completing the teardown now."
            fi
        fi
    fi
fi

# Branch teardown. `br` is empty in name mode when the worktree was detached,
# unregistered, or already gone — `git branch --list ""` matches nothing, so that
# is a clean no-op and needs no separate arm.
if [ -n "$br" ] && [ -n "$(command git branch --list "$br")" ]; then
    # ISSUE MODE deletes unconditionally, and must keep doing so. A golem branch
    # reaches teardown having been SQUASH-merged, which rewrites the commits: git
    # reports it as unmerged even though its content landed in main. Gating issue
    # mode on merge-ness would therefore refuse to delete on every ordinary
    # successful golem teardown — the common path, broken to guard the rare one.
    # Its safety story is elsewhere and is stronger: the branch had a PR, so its
    # commits are recoverable from the remote and from the merge.
    #
    # NAME MODE has neither. A scratch branch has no PR, no remote, and usually no
    # reflog an operator would think to look in; `branch -D` on it is the one
    # genuinely new destructive act this change introduces, so it is the one that
    # has to earn itself. Delete only what is already merged into GOLEM_BASE_REF;
    # otherwise remove the worktree (which is what frees the path and unblocks the
    # operator) and KEEP the branch, saying so loudly enough to act on. Fail
    # CLOSED, matching the rest of this script: an unresolvable base ref, or any
    # merge check that cannot run, keeps the branch rather than assuming merged.
    br_delete=1
    if [ "$wt_mode" = "name" ]; then
        br_delete=0
        # FULLY-QUALIFY THE BRANCH REF (#1005 review). `git rev-parse` resolves a
        # BARE name through its disambiguation order (refs/heads, refs/tags, ...),
        # so a TAG sharing the branch's name wins or loses by git's rules rather
        # than by ours. Measured on git 2.55.0: with both `refs/heads/scratch-x`
        # and `refs/tags/scratch-x` present, `scratch-x^{commit}` resolved to the
        # TAG's target, emitting only `warning: refname 'scratch-x' is ambiguous`
        # — on the stderr this line sends to /dev/null. The `branch -D` below is
        # unambiguous (it names the branch namespace), so the SAFETY CHECK would
        # have been measuring a different object than the one being deleted: a
        # tag pointing at an ancestor of the base ref would authorize deleting an
        # UNMERGED branch. `refs/heads/$br` is exact — the branch is already known
        # to exist, `git branch --list` just matched it.
        br_sha="$(command git rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null || true)"
        # GOLEM_BASE_REF cannot be qualified to ONE namespace the way `$br` can:
        # it is deliberately free-form config — `origin/main` by default, `HEAD` in
        # the test sandbox, and legitimately a tag or a raw SHA in a consuming repo
        # — so forcing a single prefix onto it would break valid values. Try each
        # unambiguous spelling in turn instead, most-specific first.
        #
        # `refs/heads` BEFORE `refs/remotes` (#1005 review cycle 2): a bare local
        # branch name is the likelier operator override, and probing the remote
        # namespace first would resolve `GOLEM_BASE_REF=main` against a remote
        # literally named `main` if one existed. The default `origin/main` is
        # unaffected — no local branch is named `origin/main`, so it falls through
        # to `refs/remotes/origin/main` exactly as before.
        #
        # THE BARE FALLBACK IS AMBIGUITY-CHECKED, NOT ASSUMED SAFE. An earlier
        # version of this comment claimed a wrong base "lands on the fail-closed
        # side, keeping the branch rather than deleting it." That claim is FALSE in
        # general and is the kind a reader would trust: it holds only when the
        # wrongly-resolved commit is an ANCESTOR of the true base. A colliding ref
        # resolving to a DESCENDANT of the branch tip makes
        # `merge-base --is-ancestor` report true, authorizing `branch -D` on a
        # genuinely unmerged branch — the same failure this cycle fixed for `$br`,
        # merely moved to the other operand. So the bare form is reached only after
        # every qualified spelling misses, and git's own `warning: refname ... is
        # ambiguous` is CAPTURED rather than discarded: an ambiguous bare base is
        # treated as unresolvable, which routes to the "could not resolve" arm and
        # keeps the branch. Fail closed on the condition, not on a hopeful claim
        # about it.
        base_sha=""
        for base_try in \
            "refs/heads/$GOLEM_BASE_REF" \
            "refs/remotes/$GOLEM_BASE_REF" \
            "refs/tags/$GOLEM_BASE_REF"; do
            base_sha="$(command git rev-parse --verify --quiet "$base_try^{commit}" 2>/dev/null || true)"
            [ -z "$base_sha" ] || break
        done
        if [ -z "$base_sha" ]; then
            # stderr is kept so the ambiguity warning can be SEEN. `--verify` alone
            # still SUCCEEDS on an ambiguous name, returning one of the candidates;
            # only the warning distinguishes it, so the text is the whole signal.
            #
            # `2>&1 >/dev/null` and not `>/dev/null 2>&1` — order is load-bearing.
            # Redirections apply left to right: the first points stderr at the
            # current stdout (the capture), the second then sends stdout to
            # /dev/null, leaving stderr captured. Reversed, stderr would follow
            # stdout into /dev/null and `base_err` would ALWAYS be empty — the
            # guard would silently never fire. Verified both spellings.
            #
            # TWO PINS, because the warning is the guard's ONLY signal and both
            # of its preconditions are caller-controlled.
            #
            # `-c core.warnAmbiguousRefs=true` (#1005 review cycle 3): that config
            # defaults to true but is an ordinary user setting, and silencing this
            # very warning in scripts is exactly why an operator would turn it off.
            # Measured on git 2.55.0 — with two colliding refs,
            # `git -c core.warnAmbiguousRefs=false rev-parse --verify 'collide^{commit}'`
            # exits 0 with EMPTY stderr and still RESOLVES the name. Without the
            # pin, that value set ANYWHERE in git's config chain — repo-local,
            # the operator's `~/.gitconfig`, or system — would silently reduce
            # this guard to the "assumed safe" posture the comment above says it
            # replaced. Scope does not matter to the outcome, only the effective
            # value does, which is why `-c` (highest precedence) is the fix; the
            # regression test plants it repo-locally as the cheapest sandboxable
            # equivalent. Env scrubbing does not help: it stops GIT_CONFIG_* from
            # redirecting which files git reads, not a value legitimately set in
            # one of them.
            #
            # `LC_ALL=C` because the match is on git's ENGLISH text. Note the
            # measured status: `refname '%s' is ambiguous.` is NOT in git's
            # translation catalogs today (checked de/fr/es — they carry
            # `ambiguous object name` and `ambiguous argument`, not this string),
            # so the pin is defensive rather than load-bearing right now, and it
            # is deliberately NOT claimed to be covered by a test. It costs
            # nothing and survives git translating the string later. Same
            # treatment, for the same reason, that the tmux kill-session dispatch
            # below gives its strerror match.
            base_err="$(LC_ALL=C command git -c core.warnAmbiguousRefs=true \
                rev-parse --verify "$GOLEM_BASE_REF^{commit}" 2>&1 >/dev/null || true)"
            base_sha="$(command git rev-parse --verify --quiet "$GOLEM_BASE_REF^{commit}" 2>/dev/null || true)"
            case "$base_err" in
                *ambiguous*)
                    command echo "worktree-rm: '$GOLEM_BASE_REF' is an ambiguous ref; refusing to measure against it." >&2
                    base_sha=""
                    ;;
            esac
        fi
        if [ -z "$base_sha" ] || [ -z "$br_sha" ]; then
            command echo "worktree-rm: kept branch $br — could not resolve it against $GOLEM_BASE_REF." >&2
            command echo "  Delete it by hand once you have checked it: git branch -D $br" >&2
        elif command git merge-base --is-ancestor "$br_sha" "$base_sha" 2>/dev/null; then
            br_delete=1
        else
            command echo "worktree-rm: kept branch $br — it is NOT merged into $GOLEM_BASE_REF." >&2
            command echo "  The worktree is gone, but the branch still holds those commits." >&2
            command echo "  Inspect with: git log $GOLEM_BASE_REF..$br" >&2
        fi
    fi
    if [ "$br_delete" -eq 1 ]; then
        command git branch -D "$br"
        command echo "  deleted branch $br"
        removed=1
    fi
fi

# Remove the per-worktree uv virtualenv worktree-new.sh seeded OFF the repo
# mount (#1091) — remove_uv_venv in cache-entry.sh, which derives and verifies
# the path through the SAME cache_entry_path the seed used (#1113). Placed AFTER
# every refusal above: a dirty or unverifiable worktree exits before this point,
# so its venv survives with it. Issue mode only — a name-mode worktree never had
# one. Best-effort: the `if` keeps a refusal or failed removal (which warn on
# stderr) from tripping `set -e`, for the same reason the tmux arm below does —
# teardown is past its destructive git steps, so failing here would strand a
# removed worktree behind a non-zero exit.
if [ "$wt_mode" = "issue" ] && remove_uv_venv "$GOLEM_UV_CACHE_DIR" "$root" "$N"; then
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

# Snapshot "something was torn down" BEFORE the repair below, which also sets
# `removed=1`: a config repair on an otherwise no-op run must not fire the
# consumer's post-remove hook, which would prune artifacts for a worktree this
# run never touched (#1092 review).
torn_down="$removed"

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

# Run the consumer's post-remove hook (#1092; contract in the header). Gated on
# `torn_down` — `removed` as it stood before the core.worktree repair. Every
# refusal has already exited 1 above, so a worktree this script declined to
# remove can never trigger a cleanup of the artifacts it still depends on. The
# repo-local fallback is resolved against `$root` (the MAIN checkout), never the
# removed worktree.
#
# Best-effort for the same reason as the tmux and uv arms: teardown is past its
# destructive steps, so a failing hook must not strand a removed worktree behind
# a non-zero exit. Bounded by bounded_run rather than GNU `timeout` (absent on
# base macOS), which also closes the hook's stdin — no TTY is ever assumed. When
# bounded, a hook that itself exits 124 reads as a timeout: bounded_run reports
# 124 for both, the same contract as timeout(1). Where bounded_run cannot bound,
# the hook runs unbounded (stdin still closed) and a 124 is reported as its own
# exit status, since no bound was applied (#1123).
if [ "$torn_down" -eq 1 ]; then
    post_hook=""
    if [ -n "$GOLEM_POST_REMOVE_HOOK" ]; then
        post_hook="$GOLEM_POST_REMOVE_HOOK"
    elif [ -e "$root/.golem/post-remove" ] || [ -L "$root/.golem/post-remove" ]; then
        post_hook="$root/.golem/post-remove"
    fi
    if [ -n "$post_hook" ]; then
        post_timeout="$GOLEM_POST_REMOVE_HOOK_TIMEOUT"
        if ! [[ "$post_timeout" =~ ^[1-9][0-9]*$ ]]; then
            command echo "worktree-rm: WARNING: GOLEM_POST_REMOVE_HOOK_TIMEOUT='$post_timeout'" \
                "is not a positive integer; using 300" >&2
            post_timeout=300
        fi
        case "$wt" in
            /*) post_wt="$wt" ;;
            *) post_wt="$root/$wt" ;;
        esac
        if [ ! -f "$post_hook" ] || [ ! -x "$post_hook" ]; then
            # Named but unrunnable is said out loud: skipping it in silence
            # would read exactly like a hook that ran and found nothing to do.
            command echo "worktree-rm: WARNING: post-remove hook $post_hook is not an" \
                "executable file; skipped" >&2
        else
            post_rc=0 post_bounded=0
            if bounded_run_available; then
                post_bounded=1
                GOLEM_WORKTREE_MODE="$wt_mode" bounded_run "$post_timeout" \
                    "$post_hook" "$N" "$root" "$post_wt" || post_rc=$?
            else
                # Unbounded, never skipped (#1123): a skip would orphan the
                # consumer's artifacts on every teardown on this host to guard a
                # hang nobody measured — the #543 shape, and the rename-aside's
                # rule (rename_timeout). </dev/null keeps the no-TTY contract
                # bounded_run otherwise provides.
                command echo "worktree-rm: WARNING: cannot bound the post-remove hook" \
                    "(sleep/mktemp/cat missing); running it unbounded" >&2
                GOLEM_WORKTREE_MODE="$wt_mode" "$post_hook" "$N" "$root" "$post_wt" \
                    </dev/null || post_rc=$?
            fi
            # A 124 is only a timeout when a bound was applied; unbounded, it is
            # the hook's own status and takes the generic arm.
            case "$post_bounded:$post_rc" in
                *:0) ;;
                1:124)
                    command echo "worktree-rm: WARNING: post-remove hook $post_hook timed" \
                        "out after ${post_timeout}s; teardown is otherwise complete" >&2
                    ;;
                *)
                    command echo "worktree-rm: WARNING: post-remove hook $post_hook exited" \
                        "$post_rc; teardown is otherwise complete" >&2
                    ;;
            esac
        fi
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
    # `br` is empty in name mode when nothing was registered to resolve it from,
    # and an empty slot in a "these were absent" list reads as a rendering bug.
    # Name the state instead. Issue mode always has a computed branch name, so
    # its message is unchanged.
    if [ "$wt_mode" = "issue" ]; then
        command echo "worktree-rm: nothing to remove for issue $N ($wt / $br / $sess absent)"
    else
        command echo "worktree-rm: nothing to remove for '$N' ($wt / $sess absent; no branch registered)"
    fi
fi
