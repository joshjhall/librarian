#!/usr/bin/env bash
# main-index-lock-check.sh — report a stale `.git/index.lock` in the MAIN
# checkout before a pull trips over it (issue #1193).
#
# THE DEFECT. In the devcontainer the main checkout is a `bindfs` FUSE overlay
# on virtiofs, and that stack occasionally keeps a directory entry for
# `index.lock` alive after git has renamed the lock over `index`. The ghost
# entry is byte-identical to `index` with the same nanosecond mtime, nothing
# holds it open, and every later git write in main — including the
# orchestrator's `git pull` — dies with `Unable to create '.git/index.lock':
# File exists`. Measured, not inferred: docs/verification/bindfs-index-lock-e2e-1193.md.
# The root cause lives in the container's mount stack, so this script does not
# fix it; it turns a late, confusing pull failure into an early, named report.
#
# READ-ONLY BY CONSTRUCTION. It runs no git command (`git status` refreshes and
# REWRITES the index — the very file under suspicion) and never removes the
# lock: deleting a lock that a live git process owns corrupts the index, and
# only a human or the caller can know nothing is running. It stats and cmp's.
#
# Usage: main-index-lock-check.sh [--repo <main-root>] [--min-age <seconds>]
#   --repo     main checkout root (default: repo_root() from config.sh, which
#              resolves MAIN even when run from inside a worktree)
#   --min-age  a lock younger than this is presumed in flight (default 60)
#
# Output (key=value lines on stdout; exit 0 for every verdict, 2 on usage):
#   verdict=none         no index.lock
#   verdict=inflight     a lock younger than --min-age — leave it alone
#   verdict=stale        a lock at least --min-age old; also prints
#                        identical=yes|no (same size, mtime and bytes as index —
#                        the #1193 ghost signature), age=<s>, and recovery=
#   verdict=unavailable  could not look; prints reason=. NEVER rendered as
#                        `none`: a check that could not run has learned nothing.

set -uo pipefail

usage() {
    printf 'usage: %s [--repo <main-root>] [--min-age <seconds>]\n' "${0##*/}" >&2
    exit 2
}

repo=""
min_age=60
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --min-age)
            [ $# -ge 2 ] || usage
            min_age="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done
case "$min_age" in '' | *[!0-9]*) usage ;; esac

unavailable() {
    printf 'verdict=unavailable\nreason=%s\n' "$1"
    exit 0
}

if [ -z "$repo" ]; then
    script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || unavailable "cannot resolve script dir"
    # shellcheck source=./config.sh
    . "$script_dir/config.sh" || unavailable "cannot source config.sh"
    repo="$(repo_root 2>/dev/null)" || unavailable "not inside a git repository"
fi

gitdir="$repo/.git"
[ -d "$gitdir" ] || unavailable "no .git directory at $repo"
index="$gitdir/index"
lock="$gitdir/index.lock"

[ -e "$lock" ] || {
    printf 'verdict=none\n'
    exit 0
}

# mtime in epoch seconds, and the full-precision form (GNU %y carries
# nanoseconds; BSD %Fm the fractional seconds) for the identity comparison.
epoch_of() { command stat -c %Y "$1" 2>/dev/null || command stat -f %m "$1" 2>/dev/null; }
fine_of() { command stat -c '%s %y' "$1" 2>/dev/null || command stat -f '%z %Fm' "$1" 2>/dev/null; }

lock_epoch="$(epoch_of "$lock")" || unavailable "cannot stat $lock"
now="$(command date +%s)" || unavailable "date failed"
age=$((now - lock_epoch))

if [ "$age" -lt "$min_age" ]; then
    printf 'verdict=inflight\nage=%s\n' "$age"
    exit 0
fi

identical=no
if [ -e "$index" ]; then
    lock_fine="$(fine_of "$lock")" || unavailable "cannot stat $lock"
    index_fine="$(fine_of "$index")" || unavailable "cannot stat $index"
    if [ "$lock_fine" = "$index_fine" ] && command cmp -s -- "$lock" "$index"; then
        identical=yes
    fi
fi

printf 'verdict=stale\nidentical=%s\nage=%s\nlock=%s\n' "$identical" "$age" "$lock"
printf 'recovery=confirm no git process holds it (fuser -v %s), then rm %s\n' "$lock" "$lock"
