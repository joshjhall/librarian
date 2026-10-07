#!/usr/bin/env bash
# Does a release tarball ship a symlink that points outside itself? (#1105)
#
#   bin/check-archive-links.sh <tarball.tar.gz>
#
# Exits 0 when every symlink in the tarball has a relative target that stays
# inside the archive's top directory, 1 (listing every offender) when one is
# absolute or climbs out with `..`, and 2 on a usage error or a tarball that
# cannot be listed, cannot be extracted, or lists nothing.
#
# WHY THIS EXISTS. The repo once tracked `.codegraph -> /cache/codegraph` (a
# devcontainer cache link). `.gitignore` said `.codegraph/`, and a trailing
# slash never matches a symlink, so `git archive` shipped the link in every
# signed tarball. joshjhall/containers extracts that tarball to /opt/librarian,
# which Claude Code is granted for edit, so the link became a prompt-free write
# path into the host's live codegraph index (joshjhall/containers#973). This
# guard runs before signing so the next such link fails the release instead.
#
# The tarball is extracted to a scratch dir and its links read with `readlink`,
# rather than parsed out of `tar -tv`, whose verbose columns differ between GNU
# tar and bsdtar. Extraction never follows a link, so an escaping one is safe to
# materialize. Resolution is LEXICAL: a target is rejected as soon as a `..`
# would climb above the archive's top directory (the first path component, e.g.
# `librarian-<version>/`) — consumers strip that component on extract, so
# escaping it already escapes the install tree. An empty listing is a failure,
# not a clean pass: a scan of zero entries proves nothing.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <tarball.tar.gz>" >&2
    exit 2
fi

tarball="$1"
if [ ! -f "$tarball" ]; then
    echo "check-archive-links: no such file: $tarball" >&2
    exit 2
fi

if ! listing="$(tar -tzf "$tarball")"; then
    echo "check-archive-links: tar could not list $tarball" >&2
    exit 2
fi
if [ -z "$listing" ]; then
    echo "check-archive-links: $tarball lists no entries" >&2
    exit 2
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-archive-links.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if ! tar -xzf "$tarball" -C "$scratch"; then
    echo "check-archive-links: tar could not extract $tarball" >&2
    exit 2
fi

# escapes <link-path-relative-to-root> <target>
# Returns 0 when <target>, resolved lexically from the link's directory, is
# absolute or climbs above the archive's top directory at any step.
escapes() {
    local rel="$1" target="$2" dir depth floor part
    case "$target" in
        /*) return 0 ;;
    esac
    dir="${rel%/*}"
    [ "$dir" = "$rel" ] && dir=""
    depth=0
    if [ -n "$dir" ]; then
        local -a dparts
        IFS=/ read -r -a dparts <<<"$dir"
        for part in "${dparts[@]}"; do
            [ -n "$part" ] && [ "$part" != "." ] && depth=$((depth + 1))
        done
    fi
    # A nested link must stay inside its top directory; a top-level one inside
    # the archive root.
    floor=0
    [ "$depth" -gt 0 ] && floor=1
    local -a tparts
    IFS=/ read -r -a tparts <<<"$target"
    for part in "${tparts[@]}"; do
        case "$part" in
            "" | .) ;;
            ..)
                depth=$((depth - 1))
                [ "$depth" -lt "$floor" ] && return 0
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
    return 1
}

links=0
bad=0
offenders=""
while IFS= read -r path; do
    [ -n "$path" ] || continue
    links=$((links + 1))
    rel="${path#"$scratch"/}"
    target="$(readlink "$path")"
    if escapes "$rel" "$target"; then
        bad=$((bad + 1))
        offenders="${offenders}  ${rel} -> ${target}
"
    fi
done <<EOF
$(find "$scratch" -type l)
EOF

if [ "$bad" -gt 0 ]; then
    echo "check-archive-links: $bad of $links symlinks in $tarball point outside the archive:" >&2
    printf '%s' "$offenders" >&2
    echo "Untrack the link (git rm --cached) and make sure .gitignore matches it without a trailing slash." >&2
    exit 1
fi

echo "check-archive-links: $links symlinks in $tarball, none absolute or escaping"
