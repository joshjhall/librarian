#!/usr/bin/env bash
# Coverage for the release toolchain: bin/release.sh, bin/lib/version-utils.sh,
# bin/generate-release-notes.sh, and bin/stamp-versions.mjs.
#
# These scripts are the single entry point for cutting every vX.Y.Z release —
# VERSION validation, semver resolution, manifest stamping, and release-note
# extraction. A silent regression here corrupts a release with no other gate to
# catch it, yet none of these paths were previously exercised by any test.
#
# Two test shapes:
#   1. Pure-function unit tests — source lib/version-utils.sh directly and assert
#      is_semver / bump_version inputs → outputs (Group A).
#   2. Hermetic end-to-end tests — release.sh and generate-release-notes.sh
#      derive their project root from ${BASH_SOURCE[0]} and `cd` into it, so they
#      cannot be redirected at a throwaway dir via cwd. Each test copies the
#      needed tree into a `mktemp -d` sandbox and runs the *copied* script there,
#      so the real VERSION / manifests / CHANGELOG are never mutated (Groups B/C).
#
# Pure bash + coreutils; the node-dependent group skips when node is absent (the
# same gating tests/run-all.sh applies). Uses the shared harness assertions.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-group
# fragments under tests/release/, and the two shared sandbox constructors live in
# tests/lib/release-sandbox.sh. The explicit FRAGMENTS list below fixes the source
# order and is guarded, so an unwired fragment cannot silently contribute zero
# tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is read by tests/lib/release-sandbox.sh and every group fragment,
# all sourced below — shellcheck analyses one file at a time and cannot see them.
# shellcheck disable=SC2034  # consumed by the sourced sandboxes/fragments, not by this file
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Release toolchain coverage"

# --- Shared sandboxes + group fragments -------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/release-sandbox.sh
source "$SCRIPT_DIR/lib/release-sandbox.sh"

source_fragments "$SCRIPT_DIR/release" \
    10-version-utils.sh \
    20-release-e2e.sh \
    30-release-notes.sh \
    40-git-automation.sh \
    50-changelog.sh \
    60-git-cliff-install.sh \
    70-stamp-versions.sh

# --- Run all tests ----------------------------------------------------------

run_fragment_test test_is_semver_accepts_valid "is_semver accepts a valid X.Y.Z"
run_fragment_test test_is_semver_rejects_invalid "is_semver rejects non-X.Y.Z strings"
run_fragment_test test_bump_version_increments "bump_version increments major/minor/patch correctly"
run_fragment_test test_bump_version_rejects_bad_type "bump_version rejects an invalid bump type"

run_fragment_test test_release_happy_path "release.sh bumps VERSION and stamps manifests (--non-interactive --force)"
run_fragment_test test_release_missing_version_file "release.sh exits 1 when the VERSION file is missing"
run_fragment_test test_release_invalid_version_arg "release.sh exits 1 on a malformed explicit version"
run_fragment_test test_release_same_version_without_force "release.sh refuses a no-op bump without --force"
run_fragment_test test_release_no_args "release.sh exits 1 with usage when given no version"

run_fragment_test test_release_notes_missing_arg "generate-release-notes.sh exits 1 with usage on no argument"
run_fragment_test test_release_notes_extracts_section "generate-release-notes.sh extracts the matching CHANGELOG section"
run_fragment_test test_release_notes_fallback_no_section "generate-release-notes.sh falls back when the version section is absent"
run_fragment_test test_release_notes_fallback_no_changelog "generate-release-notes.sh falls back when CHANGELOG.md is absent"

run_fragment_test test_git_automation_pushed_tag_defers_to_ci "git-automation: pushed tag defers to release.yml (no local gh release)"
run_fragment_test test_git_automation_unpushed_tag_creates_unsigned "git-automation: unpushed tag creates an unsigned local release"
run_fragment_test test_git_automation_no_tag_skips_release "git-automation: no tag + no push creates no release, prints manual steps"
run_fragment_test test_git_automation_push_no_tag_skips_release "git-automation: push without tag creates no release"
run_fragment_test test_git_automation_release_disabled "git-automation: AUTO_GITHUB_RELEASE=false creates no release"
run_fragment_test test_git_automation_unpushed_tag_gh_missing_degrades "git-automation: missing gh on the fallback path degrades gracefully"
run_fragment_test test_git_automation_gh_release_failure_degrades "git-automation: a failing gh release create degrades gracefully"
run_fragment_test test_git_automation_push_failure_aborts "git-automation: a failed branch push aborts with exit 1"
run_fragment_test test_git_automation_tag_push_failure_aborts "git-automation: a failed tag push aborts with exit 1"
run_fragment_test test_git_automation_not_a_git_repo "git-automation: missing .git returns 0 with a manual-commit notice"

run_fragment_test test_changelog_skip_leaves_file_untouched "changelog: --skip-changelog returns 0 and leaves CHANGELOG.md untouched"
run_fragment_test test_changelog_git_cliff_absent_returns_1_untouched "changelog: git-cliff unavailable returns 1 and leaves CHANGELOG.md untouched"
run_fragment_test test_changelog_git_cliff_runfail_returns_1 "changelog: a git-cliff run failure returns 1"
run_fragment_test test_changelog_empty_render_refuses "changelog: a headerless render is refused by the empty-render guard"
run_fragment_test test_changelog_success_trims_trailing_blanks "changelog: a valid render succeeds and trims trailing blank lines"

run_fragment_test test_release_changelog_failure_aborts_under_auto_commit "release.sh: a changelog failure aborts under --auto-commit"
run_fragment_test test_release_changelog_failure_aborts_under_auto_tag "release.sh: a changelog failure aborts under --auto-tag (second OR leg)"
run_fragment_test test_release_changelog_failure_tolerated_without_auto "release.sh: a changelog failure is tolerated without auto flags"

run_fragment_test test_ensure_git_cliff_short_circuits_when_present "git-cliff: ensure_git_cliff short-circuits when git-cliff is already on PATH"
run_fragment_test test_verify_sha512_download_failure_refuses "git-cliff: verify refuses when the .sha512 cannot be downloaded"
run_fragment_test test_verify_sha512_tampered_payload_refuses "git-cliff: verify refuses a tampered payload (digest mismatch)"
run_fragment_test test_verify_sha512_matching_payload_succeeds "git-cliff: verify succeeds when the digest matches the payload"
run_fragment_test test_verify_sha512_no_digest_tool_fails_closed "git-cliff: verify fails closed when no SHA-512 tool is available"

run_fragment_test test_ensure_git_cliff_cargo_success "git-cliff: ensure_git_cliff returns 0 when cargo installs successfully"
run_fragment_test test_ensure_git_cliff_cargo_failure_propagates "git-cliff: ensure_git_cliff propagates a cargo install failure"
run_fragment_test test_ensure_git_cliff_unsupported_arch "git-cliff: ensure_git_cliff returns 1 on an unsupported architecture"
run_fragment_test test_ensure_git_cliff_unsupported_os "git-cliff: ensure_git_cliff returns 1 on an unsupported OS"
run_fragment_test test_ensure_git_cliff_download_failure "git-cliff: ensure_git_cliff returns 1 when the tarball download fails"
run_fragment_test test_ensure_git_cliff_checksum_failure "git-cliff: ensure_git_cliff refuses to install on a checksum mismatch"
run_fragment_test test_ensure_git_cliff_tar_failure "git-cliff: ensure_git_cliff returns 1 when tar extraction fails"
run_fragment_test test_ensure_git_cliff_happy_path "git-cliff: ensure_git_cliff installs end-to-end via the binary pipeline"
run_fragment_test test_ensure_git_cliff_arm64_darwin_mapping "git-cliff: ensure_git_cliff maps arm64/darwin to the aarch64-apple-darwin asset"

run_fragment_test test_stamp_happy_path "stamp-versions.mjs stamps plugin.json + marketplace.json on a valid version"
run_fragment_test test_stamp_no_arg "stamp-versions.mjs exits 1 with no version argument"
run_fragment_test test_stamp_bad_semver "stamp-versions.mjs exits 1 on a malformed version argument"
run_fragment_test test_stamp_empty_plugins "stamp-versions.mjs exits 1 when marketplace.json has an empty plugins[]"
run_fragment_test test_stamp_missing_version_field "stamp-versions.mjs exits non-zero on a version-less plugin.json"

generate_report
