#!/usr/bin/env bash
# CHANGELOG.md generation for bin/release.sh — git-cliff wrapper + safety guards.
#
# Description:
#   Regenerates CHANGELOG.md in place from conventional commits via git-cliff,
#   with guards against the two ways git-cliff can silently wipe history (an
#   empty render, or a scope-limited run from a subdirectory/worktree).
#
# Usage:
#   . "${BIN_DIR}/lib/release/git-cliff.sh"   # provides ensure_git_cliff
#   . "${BIN_DIR}/lib/release/changelog.sh"
#   generate_changelog "$NEW_VERSION"
#
# Expected variables from the parent script:
#   SKIP_CHANGELOG   ("true" skips generation, returns 0, file untouched)
# Depends on ensure_git_cliff from lib/release/git-cliff.sh being sourced first.

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
# The caller (bin/release.sh) captures this exit code: a non-zero return HARD-
# ABORTS the release before any auto-commit/tag/push, rather than publishing a
# signed release built from a broken or wiped CHANGELOG.md (issue #233). A purely
# interactive prepare (no auto flags) still tolerates a failure with a warning so
# the human can inspect the file.
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
        # Check the trim's exit status explicitly and clean up the temp file on
        # failure — a bare `sed >tmp && mv` would both leak the temp file and,
        # under the caller's `set -e`, abort release.sh with none of this
        # function's diagnostic messaging.
        local tmp_file
        tmp_file="$(command mktemp)"
        if ! { command sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' CHANGELOG.md >"$tmp_file" && command mv "$tmp_file" CHANGELOG.md; }; then
            command rm -f "$tmp_file"
            command echo "Warning: failed to trim trailing blank lines from CHANGELOG.md" >&2
            return 1
        fi
        command echo "✓ Generated CHANGELOG.md"
        return 0
    fi
    command echo "Warning: failed to generate CHANGELOG.md" >&2
    return 1
}
