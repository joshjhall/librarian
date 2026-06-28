#!/usr/bin/env bash
# Version utility functions for the librarian release flow.
#
# Description:
#   Shared semver validation + bumping logic. Sourced by bin/release.sh.
#
# Usage:
#   . "${BIN_DIR}/lib/version-utils.sh"
#   bump_version "1.2.3" patch   # -> 1.2.4

# Header guard to prevent multiple sourcing.
if [ -n "${_LIBRARIAN_VERSION_UTILS_INCLUDED:-}" ]; then
    return 0
fi
readonly _LIBRARIAN_VERSION_UTILS_INCLUDED=1

# is_semver - strict X.Y.Z check (release tags are always full semver).
#
# Arguments:
#   $1 - version string
# Returns:
#   0 if it matches ^[0-9]+\.[0-9]+\.[0-9]+$, 1 otherwise.
is_semver() {
    command echo "$1" | command grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# bump_version - increment a semantic version.
#
# Arguments:
#   $1 - current version (X.Y.Z)
#   $2 - bump type: major | minor | patch
# Output:
#   Prints the new version to stdout. Returns 1 on an invalid bump type.
bump_version() {
    local current_version="$1"
    local bump_type="$2"
    local major minor patch

    IFS='.' read -r major minor patch <<<"$current_version"

    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            command echo "Error: invalid bump type '$bump_type'" >&2
            return 1
            ;;
    esac

    command echo "${major}.${minor}.${patch}"
}
