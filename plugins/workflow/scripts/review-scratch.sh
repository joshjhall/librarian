#!/usr/bin/env bash
# review-scratch — the ONE derivation of the ship-issue review loop's scratch
# directory (issue #1094).
#
# The review recipes write files.txt, diff.txt and each cycle's result JSON
# under $HOME/.cache/librarian-review/<gid>/, and the next cycle feeds the
# earlier JSONs back to review-convergence.sh as --prev-result history. That
# history decides `novel` vs `duplicate` and therefore when the loop stops — so
# a stale file is not clutter, it is a wrong input to a stop decision.
#
# Before #1094 three docs each spelled the derivation inline as
# `gid={GOLEM_ID or "solo"}`. GOLEM_ID is exported only by golem-launch.sh, so
# EVERY solo run shared `solo/`, which was never cleared: one machine held ~35
# files from six issues, and a refused Write of `solo/cycle1.json` left another
# issue's findings in place for convergence to read (`findings=4 novel=4` on a
# three-finding cycle). Two fixes, both here:
#
#   1. gid = $GOLEM_ID, else `solo-<issue>` — two solo runs on different issues
#      never share a directory.
#   2. `init` empties the directory — the first attempt of a review loop never
#      sees a file an earlier run left behind.
#
# WHY A SCRIPT, and not a fourth copy of the inline spelling: three copies of a
# recipe drift (that is how this bug's fallback was duplicated in the first
# place), and the callers run worktree-isolated, where the Bash tool refuses a
# command substitution (#815). So this prints key=value lines the caller READS
# — next-issue/worktree-safe-recipes.md § Pattern 1 — instead of being
# `$(...)`-captured.
#
# Usage:
#   review-scratch.sh init --issue N   # empty + create; first attempt of a loop
#   review-scratch.sh path --issue N   # create if absent, keep contents
#
# Output (stdout):
#   dir=<absolute path>
#   gid=<golem id or solo-N>
#
# Exit codes: 0 = success; 2 = usage error or an unsafe input. An unsafe input
# fails loud rather than falling back to a shared directory: falling back is
# exactly the collision this script exists to remove.
#
# Runtime: bash-only, bash-3.2 clean, BSD clean, coreutils via `command`.

set -euo pipefail

USAGE="Usage: review-scratch.sh init|path --issue N"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

[ "$#" -ge 1 ] || die "a subcommand is required"
_subcmd="$1"
shift
case "$_subcmd" in
    init | path) ;;
    *) die "unknown subcommand: $_subcmd" ;;
esac

_issue=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --issue)
            [ "$#" -ge 2 ] || die "--issue requires a value"
            _issue="$2"
            shift 2
            ;;
        *) die "unknown flag: $1" ;;
    esac
done

case "$_issue" in
    '' | *[!0-9]*) die "--issue must be an issue number (digits only), got '$_issue'" ;;
esac

# An empty GOLEM_ID is treated as unset — the same reading the inline
# `{GOLEM_ID or "solo"}` gave it.
_gid="${GOLEM_ID:-}"
if [ -z "$_gid" ]; then
    _gid="solo-$_issue"
fi
# The gid becomes one path segment under a directory `init` deletes, so it must
# not be able to name anything else: no separator, no `.`/`..`, no empty.
case "$_gid" in
    . | .. | *[!A-Za-z0-9._-]*)
        die "GOLEM_ID must be one path segment of [A-Za-z0-9._-], got '$_gid'"
        ;;
esac

[ -n "${HOME:-}" ] || die "HOME is unset or empty; refusing to guess a scratch root"
case "$HOME" in
    /*) ;;
    *) die "HOME must be an absolute path, got '$HOME'" ;;
esac

_dir="$HOME/.cache/librarian-review/$_gid"

if [ "$_subcmd" = "init" ]; then
    # No trailing slash: if $_dir is a symlink this removes the LINK, never the
    # tree it points at.
    command rm -rf -- "$_dir"
fi
command mkdir -p -- "$_dir"

command printf 'dir=%s\n' "$_dir"
command printf 'gid=%s\n' "$_gid"
