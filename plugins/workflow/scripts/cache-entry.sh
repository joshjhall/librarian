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
#   cache_entry_path  derive <cache>/[<sub>/]issue-N and verify it is ours
#   remove_uv_venv    teardown of the uv venv worktree-new.sh seeded (#1091)
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
# A trailing `/` on the root is dropped, so `/cache/venv/` and `/cache/venv`
# name the same entry on both sides.
cache_entry_path() {
    local root="${1%/}" sub="$2" n="$3"
    local target parent root_real parent_real
    target="$root/${sub:+$sub/}issue-$n"
    parent="${target%/*}"
    command printf '%s\n' "$target"
    [ ! -L "$target" ] || return 1
    if [ -n "$sub" ] && [ -L "$parent" ]; then return 1; fi
    root_real="$(command readlink -f "$root" 2>/dev/null)" || root_real=""
    parent_real="$(command readlink -f "$parent" 2>/dev/null)" || parent_real=""
    [ -n "$root_real" ] && [ "$root_real" != "/" ] &&
        [ "$parent_real" = "$root_real${sub:+/$sub}" ]
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
    local cache="$1" root="$2" n="$3" key venv
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
    if command rm -rf "$venv" 2>/dev/null && [ ! -e "$venv" ]; then
        command echo "  removed uv venv $venv"
        return 0
    fi
    command echo "worktree-rm: WARNING: could not remove uv venv $venv — delete it by hand" >&2
    return 1
}
