#!/usr/bin/env bash
# Does a release tarball ship any group- or world-writable entry? (#1101)
#
#   bin/check-archive-modes.sh <tarball.tar.gz>
#
# Exits 0 when no non-symlink entry has the group-write or other-write bit set,
# 1 (listing every offender) when one does, and 2 on a usage error or a tarball
# that cannot be listed or lists nothing.
#
# WHY THIS EXISTS. `git archive` takes each entry's mode from the tree mode
# (100644/100755/040000) masked by `tar.umask`, and an unset `tar.umask` means
# the PROCESS umask. On the GitHub runner that is 0002, so every release up to
# v0.15.0 shipped 664 files and 775 dirs. Consumers that extract as root keep
# those modes, and joshjhall/containers' trust gate then rejects the
# group-writable `scripts/` dir (joshjhall/containers#667, #1020).
# release.yml now pins `-c tar.umask=0022`; this guard runs before signing so
# a regression fails the release instead of shipping a signed bad tarball.
#
# Symlinks are skipped: their mode is always lrwxrwxrwx and is never consulted.
#
# The listing is captured whole before it is read, never piped into an early-
# exiting reader, so tar's own exit status is the one checked (no SIGPIPE
# masking under pipefail). An empty listing is a failure, not a clean pass: a
# scan of zero entries proves nothing.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <tarball.tar.gz>" >&2
    exit 2
fi

tarball="$1"
if [ ! -f "$tarball" ]; then
    echo "check-archive-modes: no such file: $tarball" >&2
    exit 2
fi

if ! listing="$(tar -tvzf "$tarball")"; then
    echo "check-archive-modes: tar could not list $tarball" >&2
    exit 2
fi

total=0
bad=0
offenders=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    mode="${line%%[[:space:]]*}"
    case "$mode" in
        l*) continue ;;
    esac
    # Mode string is `trwxrwxrwx`: index 5 is group-write, index 8 other-write.
    if [ "${mode:5:1}" = "w" ] || [ "${mode:8:1}" = "w" ]; then
        bad=$((bad + 1))
        offenders="${offenders}  ${line}
"
    fi
done <<EOF
$listing
EOF

if [ "$total" -eq 0 ]; then
    echo "check-archive-modes: $tarball lists no entries" >&2
    exit 2
fi

if [ "$bad" -gt 0 ]; then
    echo "check-archive-modes: $bad of $total entries in $tarball are group- or world-writable:" >&2
    printf '%s' "$offenders" >&2
    echo "Pin the mask when archiving: git -c tar.umask=0022 archive ..." >&2
    exit 1
fi

echo "check-archive-modes: $total entries in $tarball, none group- or world-writable"
