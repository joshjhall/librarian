#!/usr/bin/env bash
# Git automation for bin/release.sh — commit, tag, push, GitHub release.
#
# Expected variables from the parent script:
#   AUTO_COMMIT, AUTO_TAG, AUTO_PUSH, AUTO_GITHUB_RELEASE, NON_INTERACTIVE
#   GH_REPO  (e.g. joshjhall/librarian)
#
# Usage:
#   . "${BIN_DIR}/lib/release/git-automation.sh"
#   perform_git_automation "$NEW_VERSION"

perform_git_automation() {
    local new_version="$1"

    if [ ! -e .git ]; then
        command echo "Not a git repository - manual commit required"
        return 0
    fi

    if ! git diff --quiet || ! git diff --cached --quiet; then
        command echo "Note: you have uncommitted changes"
    fi

    # Auto-commit the release changes.
    if [ "$AUTO_COMMIT" = "true" ]; then
        command echo "Committing release changes..."
        git add -A
        git commit -m "chore(release): release version $new_version"
        command echo "✓ Changes committed"
    fi

    # Push the branch BEFORE tagging so a failing pre-push hook can't leave a
    # tag pointing at a commit that never validated.
    if [ "$AUTO_PUSH" = "true" ]; then
        local current_branch
        current_branch="$(git rev-parse --abbrev-ref HEAD)"

        command echo "Pushing branch $current_branch..."
        if ! git push origin "$current_branch"; then
            command echo "✗ Failed to push branch — fix the issues and retry" >&2
            exit 1
        fi
        command echo "✓ Pushed branch: $current_branch"

        if [ "$AUTO_TAG" = "true" ]; then
            command echo "Creating annotated tag v$new_version..."
            git tag -a "v$new_version" -m "Release version $new_version"
            if ! git push origin "v$new_version"; then
                command echo "✗ Failed to push tag" >&2
                exit 1
            fi
            command echo "✓ Pushed tag: v$new_version"
        fi
    elif [ "$AUTO_TAG" = "true" ]; then
        # Not pushing — create the tag locally only.
        command echo "Creating annotated tag v$new_version (local only)..."
        git tag -a "v$new_version" -m "Release version $new_version"
        command echo "✓ Tag created"
    fi

    # Create the GitHub release.
    #
    # When the tag was pushed to origin (AUTO_PUSH + AUTO_TAG), the
    # tag-triggered release.yml workflow is the CANONICAL publisher: it
    # re-validates the tree, then cosign-keyless-signs a git-archive tarball and
    # attaches the .tar.gz/.sig/.pem assets (see .github/workflows/release.yml
    # and README ## Verifying a release). A local `gh release create` here can't
    # do keyless signing (no GitHub OIDC token off-CI) and would race CI to
    # publish an UNSIGNED release, so skip it and let CI own the signed release.
    if [ "$AUTO_GITHUB_RELEASE" = "true" ] && [ "$AUTO_PUSH" = "true" ] && [ "$AUTO_TAG" = "true" ]; then
        command echo "Tag v$new_version pushed — release.yml will publish the signed GitHub release."
        command echo "  Track it: https://github.com/${GH_REPO}/actions/workflows/release.yml"
    elif [ "$AUTO_GITHUB_RELEASE" = "true" ]; then
        # Tag was NOT pushed (local-only): CI won't fire, so create an
        # unsigned local release as a fallback. Signed assets require the
        # tag-push CI path above.
        if ! command -v gh >/dev/null 2>&1; then
            command echo "Warning: gh CLI not found, skipping GitHub release" >&2
        else
            local release_notes
            release_notes="$("${BIN_DIR}/generate-release-notes.sh" "$new_version" 2>/dev/null ||
                command echo "See [CHANGELOG.md](https://github.com/${GH_REPO}/blob/v${new_version}/CHANGELOG.md) for details.")"

            command echo "Note: creating an UNSIGNED release (tag not pushed, so release.yml did not run)." >&2
            if gh release create "v$new_version" \
                --title "Release v$new_version" \
                --notes "$release_notes"; then
                command echo "✓ GitHub release created: https://github.com/${GH_REPO}/releases/tag/v$new_version"
            else
                command echo "Warning: failed to create GitHub release" >&2
                command echo "Create it manually: https://github.com/${GH_REPO}/releases/new?tag=v$new_version"
            fi
        fi
    fi

    # Show the remaining manual steps when not fully automated.
    if [ "$AUTO_COMMIT" = "false" ] || [ "$AUTO_TAG" = "false" ] || [ "$AUTO_PUSH" = "false" ]; then
        command echo ""
        command echo "To complete the release, run:"
        if [ "$AUTO_COMMIT" = "false" ]; then
            command echo "  git add -A"
            command echo "  git commit -m \"chore(release): release version $new_version\""
        fi
        if [ "$AUTO_TAG" = "false" ]; then
            command echo "  git tag -a v$new_version -m \"Release version $new_version\""
        fi
        if [ "$AUTO_PUSH" = "false" ]; then
            command echo "  git push origin <branch>"
            command echo "  git push origin v$new_version"
        fi
        command echo ""
        command echo "Pushing the v$new_version tag triggers GitHub Actions to validate the"
        command echo "tagged tree and publish the GitHub Release. The tag is what"
        command echo "containers' LIBRARIAN_REF pins to."
    fi
}
