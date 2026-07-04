#!/usr/bin/env bash
# Release management for the librarian plugin marketplace.
#
# Cuts a repo-level semver release: bumps the VERSION file, stamps every plugin
# manifest in lockstep, regenerates CHANGELOG.md from conventional commits, and
# (optionally) commits, tags `vX.Y.Z`, pushes, and publishes a GitHub Release.
#
# The repo-level `vX.Y.Z` tag is the unit containers' LIBRARIAN_REF pins to —
# it pins the whole marketplace at once. Per-plugin semver in each plugin.json
# can advance independently between releases; a release re-aligns them all to
# the repo version.
#
# NEVER edit the VERSION file by hand — always go through this script (or the
# `just release-*` recipes) so the manifests and changelog stay consistent.
set -euo pipefail

# Release automation flags (consumed by the sourced git-automation.sh).
export AUTO_COMMIT=false
export AUTO_TAG=false
export AUTO_PUSH=false
export AUTO_GITHUB_RELEASE=false

# GitHub repo slug used for release URLs / notes.
export GH_REPO="${GH_REPO:-joshjhall/librarian}"

BIN_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(/usr/bin/dirname "$BIN_DIR")"
export BIN_DIR

# shellcheck source=lib/version-utils.sh
. "${BIN_DIR}/lib/version-utils.sh"
# shellcheck source=lib/release/git-cliff.sh
. "${BIN_DIR}/lib/release/git-cliff.sh"
# shellcheck source=lib/release/git-automation.sh
. "${BIN_DIR}/lib/release/git-automation.sh"

cd "$PROJECT_ROOT"

usage() {
    command cat <<EOF
Usage: $0 [OPTIONS] <major|minor|patch|X.Y.Z>

Options:
  --force                 Re-stamp even if the version is unchanged
  --skip-changelog        Skip CHANGELOG.md regeneration
  --non-interactive       Skip the confirmation prompt (CI/CD)
  --auto-commit           Commit the release changes
  --auto-tag              Create the annotated vX.Y.Z tag
  --auto-push             Push the branch (then the tag, if --auto-tag)
  --auto-github-release   Publish a GitHub Release
  --full-auto             All of the above, non-interactive

Examples:
  $0 patch                     # 0.1.0 -> 0.1.1
  $0 minor                     # 0.1.0 -> 0.2.0
  $0 1.2.3                     # set an explicit version
  $0 --non-interactive patch   # no prompt (CI)

Current version: $(command cat VERSION 2>/dev/null || command echo "<no VERSION file>")
EOF
    exit 1
}

if [ ! -f VERSION ]; then
    command echo "Error: VERSION file not found" >&2
    exit 1
fi

CURRENT_VERSION="$(command cat VERSION)"
if ! is_semver "$CURRENT_VERSION"; then
    command echo "Error: VERSION file holds an invalid version: '$CURRENT_VERSION'" >&2
    exit 1
fi

FORCE_UPDATE=false
SKIP_CHANGELOG=false
NON_INTERACTIVE=false
VERSION_ARG=""

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE_UPDATE=true ;;
        --skip-changelog) SKIP_CHANGELOG=true ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        --auto-commit) AUTO_COMMIT=true ;;
        --auto-tag) AUTO_TAG=true ;;
        --auto-push) AUTO_PUSH=true ;;
        --auto-github-release) AUTO_GITHUB_RELEASE=true ;;
        --full-auto)
            AUTO_COMMIT=true
            AUTO_TAG=true
            AUTO_PUSH=true
            AUTO_GITHUB_RELEASE=true
            NON_INTERACTIVE=true
            ;;
        -h | --help) usage ;;
        -*)
            command echo "Error: unknown option '$1'" >&2
            usage
            ;;
        *)
            if [ -z "$VERSION_ARG" ]; then
                VERSION_ARG="$1"
            else
                command echo "Error: multiple version arguments: '$VERSION_ARG' and '$1'" >&2
                usage
            fi
            ;;
    esac
    shift
done

[ -z "$VERSION_ARG" ] && usage

# Resolve the target version.
if command echo "$VERSION_ARG" | command grep -qE '^(major|minor|patch)$'; then
    NEW_VERSION="$(bump_version "$CURRENT_VERSION" "$VERSION_ARG")"
else
    NEW_VERSION="$VERSION_ARG"
    if ! is_semver "$NEW_VERSION"; then
        command echo "Error: invalid version format '$NEW_VERSION' (expected X.Y.Z)" >&2
        exit 1
    fi
fi

command echo "Current version: $CURRENT_VERSION"
command echo "New version:     $NEW_VERSION"

if [ "$CURRENT_VERSION" = "$NEW_VERSION" ] && [ "$FORCE_UPDATE" = "false" ]; then
    command echo "Version is already $NEW_VERSION. Use --force to re-stamp anyway." >&2
    exit 1
fi

# Regenerate CHANGELOG.md in place from conventional commits for $new_version
# ($1), via git-cliff. This mutates CHANGELOG.md as a side effect. Return paths
# and the resulting file state:
#   --skip-changelog set   -> returns 0, file left untouched.
#   git-cliff unavailable  -> returns 1, file left untouched.
#   git-cliff run failed   -> returns 1; CHANGELOG.md left in whatever partial
#                             state git-cliff wrote before failing — do NOT trust it.
#   empty-render guard hit -> returns 1 (no "## [$new_version]" section, i.e.
#                             git-cliff produced a headerless changelog); file
#                             is left as git-cliff wrote it — do NOT commit it.
#   success                -> returns 0, file regenerated with trailing blank
#                             lines trimmed (MD012).
# The sole caller swallows the exit code (`generate_changelog ... || true`), so
# anything relying on the outcome must inspect CHANGELOG.md's content itself.
generate_changelog() {
    local new_version="$1"

    if [ "$SKIP_CHANGELOG" = "true" ]; then
        command echo "Skipping CHANGELOG generation"
        return 0
    fi

    command echo "Generating CHANGELOG.md..."
    if ! ensure_git_cliff; then
        command echo "Warning: git-cliff unavailable, skipping CHANGELOG generation" >&2
        command echo "  Install git-cliff, then: git-cliff -o CHANGELOG.md --tag v$new_version --include-path '**/*'" >&2
        return 1
    fi

    # --include-path '**/*' forces full-repo commit scope. git-cliff 2.x
    # otherwise scopes commits to the current directory, so running this script
    # from a subdirectory or a linked worktree (e.g. .claude/worktrees/*, as in
    # a bare-repo checkout) yields an EMPTY changelog while still exiting 0 — a
    # silent wipe of the existing history. The glob pins scope to the whole repo
    # regardless of the working directory the release is cut from.
    if git-cliff -o CHANGELOG.md --tag "v$new_version" --include-path '**/*'; then
        # Guard against a silent empty render: git-cliff exits 0 even when it
        # produces only the header (no version sections), which would commit a
        # wiped changelog. Require the new version's section to be present.
        if ! command grep -q "## \[$new_version\]" CHANGELOG.md; then
            command echo "Error: generated CHANGELOG.md has no [$new_version] section" >&2
            command echo "  (git-cliff produced an empty/headerless changelog — refusing to wipe history)" >&2
            return 1
        fi
        # Trim trailing blank lines so the file passes markdown lint (MD012).
        local tmp_file
        tmp_file="$(command mktemp)"
        command sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' CHANGELOG.md >"$tmp_file" && command mv "$tmp_file" CHANGELOG.md
        command echo "✓ Generated CHANGELOG.md"
        return 0
    fi
    command echo "Warning: failed to generate CHANGELOG.md" >&2
    return 1
}

if [ "$NON_INTERACTIVE" = "false" ]; then
    command echo ""
    read -r -p "Continue with release v$NEW_VERSION? (y/n) " -n 1 reply
    command echo ""
    if ! command echo "$reply" | command grep -qE '^[Yy]$'; then
        command echo "Release cancelled. For automation: $0 --non-interactive $VERSION_ARG" >&2
        exit 1
    fi
fi

# 1. Bump the VERSION file.
command echo "$NEW_VERSION" >VERSION
command echo "✓ Updated VERSION"

# 2. Stamp every plugin manifest in lockstep (keeps validate-manifests green).
node "${BIN_DIR}/stamp-versions.mjs" "$NEW_VERSION"
node "${PROJECT_ROOT}/tests/validate-manifests.mjs"

# 3. Regenerate the changelog.
command echo ""
generate_changelog "$NEW_VERSION" || true

command echo ""
command echo "✓ Release $NEW_VERSION prepared."
command echo "Updated: VERSION, marketplace.json, plugins/*/plugin.json$([ "$SKIP_CHANGELOG" = "false" ] && command echo ", CHANGELOG.md")"
command echo ""

# 4. Optional git automation (commit / tag / push / GitHub release).
perform_git_automation "$NEW_VERSION"
