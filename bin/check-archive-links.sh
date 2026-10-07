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
# materialize. A target is rejected when it is absolute, when a `..` would climb
# above the archive's top directory (the first path component, e.g.
# `librarian-<version>/`, which becomes the install tree once extracted) — even
# transiently, as in `../../librarian-<version>/x` — or when it routes THROUGH
# another symlink. That last rule is what makes the depth walk sound: the
# kernel resolves a target component by component, so `a/t -> s/../..` with
# `a/s -> ..` climbs from wherever `s` lands, not from `a/s`, and a purely
# lexical count would pass a chain that escapes while each link alone looks
# in-tree. With no symlink mid-path, every component walked is a real
# directory and the count is exact. A link with no directory component (an
# archive built without a prefix) is held to the archive root instead. An
# empty listing is a failure, not a clean pass: a scan of zero entries proves
# nothing.

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
# Returns 0 (printing the reason) when <target>, walked from the link's
# directory, is absolute, climbs above the archive's top directory at any step,
# or passes through another symlink before its final component.
escapes() {
    local rel="$1" target="$2" dir cur depth floor part i n
    case "$target" in
        /*)
            echo "absolute"
            return 0
            ;;
    esac
    dir="${rel%/*}"
    [ "$dir" = "$rel" ] && dir=""
    cur="$dir"
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
    n=${#tparts[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        part="${tparts[$i]}"
        i=$((i + 1))
        case "$part" in
            "" | .) ;;
            ..)
                depth=$((depth - 1))
                if [ "$depth" -lt "$floor" ]; then
                    echo "climbs out"
                    return 0
                fi
                case "$cur" in
                    */*) cur="${cur%/*}" ;;
                    *) cur="" ;;
                esac
                ;;
            *)
                depth=$((depth + 1))
                cur="${cur:+$cur/}$part"
                if [ "$i" -lt "$n" ] && [ -L "$scratch/$cur" ]; then
                    echo "routes through symlink $cur"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

links=0
bad=0
offenders=""
# NUL-delimited so a link name holding a newline cannot split into fragments.
# Captured to a file first, never read through a process substitution, so a
# failing find is an error rather than a scan of zero links that reads as clean.
# The list lives in the scratch dir; it is a regular file, so -type l skips it.
list="$scratch/.check-archive-links.list"
if ! find "$scratch" -type l -print0 >"$list"; then
    echo "check-archive-links: could not scan the extracted tree" >&2
    exit 2
fi
while IFS= read -r -d '' path; do
    links=$((links + 1))
    rel="${path#"$scratch"/}"
    target="$(readlink "$path")"
    if why="$(escapes "$rel" "$target")"; then
        bad=$((bad + 1))
        offenders="${offenders}  ${rel} -> ${target}  (${why})
"
    fi
done <"$list"

if [ "$bad" -gt 0 ]; then
    echo "check-archive-links: $bad of $links symlinks in $tarball point outside the archive:" >&2
    printf '%s' "$offenders" >&2
    echo "Untrack the link (git rm --cached) and make sure .gitignore matches it without a trailing slash." >&2
    exit 1
fi

echo "check-archive-links: $links symlinks in $tarball, none absolute or escaping"
