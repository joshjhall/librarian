#!/usr/bin/env bash
# cache-entry.sh — the per-issue CACHE ENTRY path, derived and verified in ONE
# place for both the seed (worktree-new.sh) and the teardown (worktree-rm.sh)
# (issue #1113, extracted from worktree-rm.sh's #1091 uv-venv block).
#
# Sourced, not executed. Both scripts source it right after config.sh:
#
#     # shellcheck source=./cache-entry.sh
#     . "$SCRIPT_DIR/cache-entry.sh"
#
# WHY ONE FUNCTION. worktree-new.sh seeds `<cache>/<key>/issue-N` into a
# worktree's settings and worktree-rm.sh later `rm -rf`s the same path. Each side
# used to derive that path and apply the "canonical parent == canonical root +
# key, no symlinks" rule on its own, so the two copies had to stay in agreement
# by hand — and a disagreement means teardown deletes a path the seed never
# owned, or leaks one it did. Now both call cache_entry_path:
#
#   cache_entry_path   derive <cache>/[<sub>/]issue-N and verify it is ours
#   cache_entry_owned  verify the entry (and its <sub> parent) is OWNED by us (#1115)
#   cache_entry_remove delete a verified entry RELATIVE to its re-verified parent (#1115)
#   remove_uv_venv     teardown of the uv venv worktree-new.sh seeded (#1091)
#
# THE PARENT'S GLOBALS this file touches: none. Every input is an argument, and
# remove_uv_venv reports a removal through its exit status (the caller sets its
# own `removed`). It calls golem_repo_key, so config.sh is sourced first. Every
# function is only DEFINED here; nothing runs at source time.
#
# bash-3.2 clean, BSD-tool clean, per CLAUDE.md § Runtime policy.

# cache_entry_path <cache-root> <sub> <N> — print the cache entry
# `<cache-root>/[<sub>/]issue-N` and return 0 only when that path sits where it
# SAYS. Returns 1 otherwise, but still prints the path, so a caller refusing it
# can name what it refused.
#
# The cache root is a shared mount and a <sub> key is predictable, so a planted
# `<cache>/<key> -> /elsewhere` would aim a seed's `mkdir -p` — or a teardown's
# `rm -rf` — at /elsewhere/issue-N (#1091 review c2/c5). So SYMLINKS are refused
# at every level below the root: the leaf must not be a link, nor the <sub>
# parent, and the parent, canonicalized, must equal the canonical root plus
# <sub>. The root ITSELF may legitimately be a symlink (an operator pointing
# /cache/target at a bigger disk — #944's symlinked-cache test pins that); the
# canonical comparison already accounts for it. A root that canonicalizes to `/`
# (e.g. `//`) is refused, and where `readlink -f` cannot run the path is
# unverifiable and refused: an unverifiable path is neither seeded nor deleted.
#
# What it does NOT cover: the check is one snapshot of a NAME. A caller that
# then acts on the path by name follows a link swapped in AFTER the check. The
# teardown no longer does: it deletes through cache_entry_remove, which enters
# the directory, re-verifies where it physically landed, and acts relative to
# that cwd (#1115). The SEED still acts by name (`mkdir -p`), so a swap between
# this check and its mkdir is still followed there. Nor does this function
# check OWNERSHIP — that is cache_entry_owned, below.
#
# <N> must be all digits: the check verifies only the PARENT, so an <N> carrying
# `/` or `..` (`7/../..`) would verify against an existing issue-7 and aim the
# caller at the cache root itself. Both callers validate <N> today; this keeps
# the one shared check from trusting them to.
#
# A trailing `/` on the root is dropped, so `/cache/venv/` and `/cache/venv`
# name the same entry on both sides.
cache_entry_path() {
    local root="${1%/}" sub="$2" n="$3"
    local target parent root_real parent_real
    target="$root/${sub:+$sub/}issue-$n"
    parent="${target%/*}"
    command printf '%s\n' "$target"
    case "$n" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ ! -L "$target" ] || return 1
    if [ -n "$sub" ] && [ -L "$parent" ]; then return 1; fi
    root_real="$(command readlink -f "$root" 2>/dev/null)" || root_real=""
    parent_real="$(command readlink -f "$parent" 2>/dev/null)" || parent_real=""
    [ -n "$root_real" ] && [ "$root_real" != "/" ] &&
        [ "$parent_real" = "$root_real${sub:+/$sub}" ]
}

# cache_entry_owned <target> <sub> — return 0 only when <target> is owned by
# the current user and, when <sub> is non-empty, so is its <sub> parent (#1115).
#
# cache_entry_path proves WHERE a path is, not WHOSE it is. On a cache root
# shared with another uid, a co-tenant can pre-create the predictable
# `<cache>/<key>` or `<cache>/<key>/issue-N` (no symlink needed): the seed would
# then point a worktree's venv — executable Python — into a directory that
# co-tenant controls, and teardown would `rm -rf` a directory that is not ours.
# A path that does not exist is not owned, so the seed calls this AFTER its
# `mkdir -p`.
#
# The parent is checked only in the KEYED shape: keyless (the cargo shape), the
# parent IS the operator-chosen cache root, which may legitimately belong to
# someone else (root-owned /cache with a world-writable mode). `-O` is POSIX
# `test`, so this stays bash-3.2 and BSD clean.
#
# Called by NAME (the seed, after its mkdir) this is one snapshot like
# cache_entry_path, so a swap after it is still followed there. Teardown does
# not use it: cache_entry_remove runs the same `-O` checks on `.` from inside
# each re-verified directory, where a later swap of the path cannot redirect it.
cache_entry_owned() {
    local target="$1" sub="$2"
    [ -O "$target" ] || return 1
    if [ -n "$sub" ] && [ ! -O "${target%/*}" ]; then return 1; fi
    return 0
}

# cache_entry_remove <parent> <expect> <sub> <N> — delete <parent>/issue-N,
# where <expect> is the canonical path <parent> MUST physically be. Returns 0
# removed, 1 the removal failed, 2 a directory was not where it was expected
# (a symlink, or a swap since the caller's check), 3 not owned by us.
#
# Closes the window between cache_entry_path's check and a by-name `rm -rf`
# (#1115): a co-tenant who swaps `<cache>/<key>` for a link after the check
# would aim that rm at /elsewhere/issue-N. Here nothing is resolved by name
# after entry. In a subshell: `cd -P` into <parent>, require `pwd -P` == <expect>
# (and, keyed, ownership); then `cd -P` into issue-N in a NESTED subshell,
# require it to be that verified cwd + /issue-N and ours, and empty it with `find . -mindepth 1 -delete`
# (find never follows a link, and -delete implies -depth); then, back in the
# pinned parent cwd, `rmdir -- issue-N` — which fails on a link rather than
# following it. Once the cwd IS the verified directory, renaming or relinking its
# path cannot redirect a relative operation: it resolves against the cwd's inode.
#
# What it does NOT cover — the cd->delete window that remains. After the
# `pwd -P` re-check the cwd is pinned by inode, so a later rename or relink of
# its PATH changes nothing: the delete still hits that inode, which we verified
# and own. What is left is a writer INSIDE our own directories: one with write
# access to the verified <key> dir can swap the name `issue-N` between `find`
# and `rmdir` (rmdir refuses a link and removes only an EMPTY dir, so the worst
# case is an empty dir of theirs), and one with write access inside issue-N can
# add entries while `find` runs (find never follows a link, so they cannot aim
# it outside). Both need write access to a directory we own — the ownership
# check bounds who that can be. `find -mindepth`/`-delete` are in both BSD and
# GNU find.
cache_entry_remove() {
    local parent="$1" expect="$2" sub="$3" n="$4" here
    (
        command cd -P -- "$parent" 2>/dev/null || exit 2
        here="$(command pwd -P)"
        # The ONLY guard on the parent: the leaf check below is relative to
        # wherever this landed, so it cannot catch a wrong parent for us.
        [ "$here" = "$expect" ] || exit 2
        if [ -n "$sub" ] && [ ! -O . ]; then exit 3; fi
        (
            command cd -P -- "issue-$n" 2>/dev/null || exit 2
            # The ONLY guard on the leaf: a link named issue-N lands elsewhere.
            [ "$(command pwd -P)" = "$here/issue-$n" ] || exit 2
            [ -O . ] || exit 3
            command find . -mindepth 1 -delete 2>/dev/null || exit 1
        ) || exit $?
        command rmdir -- "issue-$n" 2>/dev/null || exit 1
    )
}

# remove_uv_venv <cache-root> <repo-root> <N> — remove the per-worktree uv
# virtualenv worktree-new.sh seeded OFF the repo mount (#1091). It lives under
# the cache, not in the worktree, so removing the worktree does not remove it
# and nothing else ever would. Returns 0 ONLY when it removed something; the
# caller sets `removed=1` on that.
#
# Issue mode only (the caller gates it) — worktree-new.sh keys the venv by issue
# number and never creates one for a name-mode worktree. The path is
# <cache>/<golem_repo_key>/issue-N, from cache_entry_path, the SAME function the
# seed used: keyed by repo as well as issue, because the cache is shared across
# repos and another repo's issue N is somebody else's live venv. <N> is a
# validated number, and the cache must be ABSOLUTE (a relative one would resolve
# inside this checkout).
#
# A refusal of an EXISTING venv says so on stderr — a silent skip would leak the
# venv while reading exactly like "there was nothing to remove". Best-effort: a
# failed removal warns and returns 1, never aborting the caller — teardown is
# past its destructive git steps by now, so failing here would strand a removed
# worktree behind a non-zero exit.
remove_uv_venv() {
    local cache="$1" root="$2" n="$3" key venv root_real rc
    case "$cache" in
        /?*) ;;
        *) return 1 ;;
    esac
    key="$(golem_repo_key "$root")" || key=""
    if [ -z "$key" ]; then
        # No key means no path to check — so say so when a venv COULD exist (the
        # cache root is present), rather than skip in silence (#1091 pr-review c4).
        if [ -d "$cache" ]; then
            command echo "worktree-rm: WARNING: could not derive the repo key for $root —" \
                "any uv venv for issue $n under $cache was left in place" >&2
        fi
        return 1
    fi
    if ! venv="$(cache_entry_path "$cache" "$key" "$n")"; then
        if [ -e "$venv" ] || [ -L "$venv" ]; then
            command echo "worktree-rm: WARNING: refusing to remove uv venv $venv —" \
                "it is, or sits under, a symlink (or its path could not be verified); inspect it by hand" >&2
        fi
        return 1
    fi
    [ -d "$venv" ] || return 1
    # cache_entry_path succeeded, so the root canonicalizes; this is the path
    # the parent must PHYSICALLY be once cache_entry_remove has entered it.
    root_real="$(command readlink -f "$cache" 2>/dev/null)" || root_real=""
    rc=2
    if [ -n "$root_real" ]; then
        cache_entry_remove "${venv%/*}" "$root_real/$key" "$key" "$n"
        rc=$?
    fi
    case "$rc" in
        0)
            command echo "  removed uv venv $venv"
            return 0
            ;;
        2)
            command echo "worktree-rm: WARNING: refusing to remove uv venv $venv —" \
                "it moved, or became a symlink, after it was verified; inspect it by hand" >&2
            ;;
        3)
            command echo "worktree-rm: WARNING: refusing to remove uv venv $venv —" \
                "it, or its parent, is not owned by you; inspect it by hand" >&2
            ;;
        *)
            command echo "worktree-rm: WARNING: could not remove uv venv $venv — delete it by hand" >&2
            ;;
    esac
    return 1
}
