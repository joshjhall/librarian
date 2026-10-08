#!/usr/bin/env bash
# probe-fuse-rename.sh — replay git's index-lock protocol on a filesystem and
# count the times the filesystem lies about it (issue #1193).
#
# WHY. During a golem run the main checkout's `.git/index.lock` was repeatedly
# left behind byte-identical to `.git/index` with the SAME nanosecond mtime —
# the signature of a directory entry that outlived the rename which consumed
# it. The main checkout in the devcontainer is a `bindfs` FUSE overlay stacked
# on virtiofs. This probe needs no git and no second process: one writer does
# exactly what git does for every index write —
#
#   1. create `index.lock` exclusively (O_EXCL, via noclobber)
#   2. write it
#   3. rename it over `index`
#
# — and after each cycle checks the three things a correct filesystem
# guarantees: the exclusive create succeeds (no lock is left over), the rename
# finds the file it was just handed, and `index.lock` is gone afterwards.
# Every anomaly branch removes the lock before the next cycle, so a refused
# exclusive create on the cycle after a fault is the filesystem's doing, not a
# leftover of the probe's own. Measured on 2026-10-07 (after that cleanup was
# added): 16 anomaly rows forming 9 fault episodes, plus one write to a
# just-created lock failing ENOENT (now counted as write-lost-file), in 20,000
# cycles on the bindfs mount; 0 in 12,000 on the container's overlay /tmp. Evidence and the full analysis:
# docs/verification/bindfs-index-lock-e2e-1193.md.
#
# Usage: bin/probe-fuse-rename.sh <existing-dir> [cycles]   (default 2000)
#
# Runs inside a fresh `probe-fuse-rename.XXXXXX` subdirectory of <dir> and
# removes only that subdirectory. Never point it at a live `.git` directory —
# it is a stand-in for one, not a test of one.
#
# Output: one `anomaly=<kind> cycle=<n> ...` row per anomaly (with `stat` rows
# for both names), then `cycles=<n> anomalies=<n> fs=<type>`.
# Exit: 0 clean, 1 at least one anomaly, 2 usage error.

set -uo pipefail

usage() {
    printf 'usage: %s <existing-dir> [cycles]\n' "${0##*/}" >&2
    exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
base="${1:?}"
cycles="${2:-2000}"
case "$cycles" in '' | *[!0-9]*) usage ;; esac
[ -d "$base" ] || {
    printf 'probe-fuse-rename: not a directory: %s\n' "$base" >&2
    exit 2
}
case "$base" in /) {
    printf 'probe-fuse-rename: refusing to run at /\n' >&2
    exit 2
} ;; esac

work="$(command mktemp -d "$base/probe-fuse-rename.XXXXXX")" || {
    printf 'probe-fuse-rename: cannot create a scratch dir under %s\n' "$base" >&2
    exit 2
}
trap 'command rm -rf -- "${work:?}"' EXIT

# A stat row for one name: inode, size, mtime — GNU first, then BSD (%Fm keeps
# the fractional seconds, which is what makes "same mtime" a strong signal).
stat_row() {
    command stat -c '%i %s %y' "$1" 2>/dev/null ||
        command stat -f '%i %z %Fm' "$1" 2>/dev/null ||
        printf 'absent'
}

report() { # report <kind> <cycle>
    printf 'anomaly=%s cycle=%s index=[%s] lock=[%s]\n' "$1" "$2" \
        "$(stat_row "$work/index")" "$(stat_row "$work/index.lock")"
    anomalies=$((anomalies + 1))
}

payload="$work/payload"
command head -c 150000 /dev/urandom >"$payload" 2>/dev/null ||
    command dd if=/dev/urandom of="$payload" bs=1000 count=150 2>/dev/null

anomalies=0
i=0
while [ "$i" -lt "$cycles" ]; do
    i=$((i + 1))
    if ! (
        set -o noclobber
        : >"$work/index.lock"
    ) 2>/dev/null; then
        # Exclusive create refused: a lock is "there" although the last cycle
        # renamed it away. This is the failure `git pull` reported.
        report exclusive-create-refused "$i"
        command rm -f -- "$work/index.lock"
        continue
    fi
    if ! command cat "$payload" >"$work/index.lock" 2>/dev/null; then
        # The lock this cycle just created exclusively has vanished.
        report write-lost-file "$i"
        command rm -f -- "$work/index.lock"
        continue
    fi
    if ! command mv -f -- "$work/index.lock" "$work/index" 2>/dev/null; then
        report rename-lost-source "$i"
        # Clear whatever is left so the NEXT cycle's exclusive create is not
        # refused by this cycle's leftover — that would count one fault twice.
        command rm -f -- "$work/index.lock"
        continue
    fi
    if [ -e "$work/index.lock" ]; then
        report lock-visible-after-rename "$i"
        command rm -f -- "$work/index.lock"
    fi
done

fs="$(command stat -f -c %T "$work" 2>/dev/null || printf 'unknown')"
printf 'cycles=%s anomalies=%s fs=%s\n' "$cycles" "$anomalies" "$fs"
[ "$anomalies" -eq 0 ]
