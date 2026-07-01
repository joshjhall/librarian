#!/usr/bin/env bash
# Coverage for the release toolchain: bin/release.sh, bin/lib/version-utils.sh,
# and bin/generate-release-notes.sh.
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Release toolchain coverage"

# --- Sandbox helpers --------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits. Each sandbox is
# a fresh subdir under it, so a per-helper RETURN trap (which would fire when the
# helper returns, before the test body runs) is unnecessary.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# make_bin_sandbox <varname>
# Creates a fresh sandbox subdir with a copy of bin/ and a synthetic VERSION
# (1.2.3), and assigns its path to the caller's named variable. Enough for
# release.sh's pre-node error paths and for generate-release-notes.sh (which
# sources nothing).
make_bin_sandbox() {
    local __out="$1"
    local dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    command cp -R "$REPO_ROOT/bin" "$dir/bin"
    command printf '1.2.3\n' >"$dir/VERSION"
    printf -v "$__out" '%s' "$dir"
}

# make_full_sandbox <varname>
# As make_bin_sandbox, plus the manifests and validator release.sh stamps on its
# happy path: tests/validate-manifests.mjs, .claude-plugin/, and plugins/. The
# copied manifests are internally valid; release.sh restamps them all to the new
# version, so the initial VERSION≠manifest skew is harmless.
make_full_sandbox() {
    local __out="$1"
    local dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    command cp -R "$REPO_ROOT/bin" "$dir/bin"
    command mkdir -p "$dir/tests"
    command cp "$REPO_ROOT/tests/validate-manifests.mjs" "$dir/tests/"
    command cp -R "$REPO_ROOT/.claude-plugin" "$dir/.claude-plugin"
    command cp -R "$REPO_ROOT/plugins" "$dir/plugins"
    command printf '1.2.3\n' >"$dir/VERSION"
    printf -v "$__out" '%s' "$dir"
}

# --- Group A: version-utils.sh unit tests -----------------------------------

# shellcheck source=bin/lib/version-utils.sh
source "$REPO_ROOT/bin/lib/version-utils.sh"

test_is_semver_accepts_valid() {
    local rc=0
    is_semver "1.2.3" || rc=$?
    assert_exit 0 "$rc" "is_semver accepts 1.2.3"
}

test_is_semver_rejects_invalid() {
    local bad rc
    for bad in "1.2" "1.2.3.4" "v1.2.3" "1.2.3-alpha" ""; do
        rc=0
        is_semver "$bad" || rc=$?
        assert_exit 1 "$rc" "is_semver rejects '$bad'"
    done
}

test_bump_version_increments() {
    assert_equals "1.2.4" "$(bump_version 1.2.3 patch)" "patch bump"
    assert_equals "1.3.0" "$(bump_version 1.2.3 minor)" "minor bump resets patch"
    assert_equals "2.0.0" "$(bump_version 1.2.3 major)" "major bump resets minor+patch"
}

test_bump_version_rejects_bad_type() {
    local rc=0 err
    err="$(bump_version 1.2.3 bogus 2>&1 >/dev/null)" || rc=$?
    assert_true "[ $rc -ne 0 ]" "bump_version exits non-zero on an invalid bump type"
    assert_contains "$err" "invalid bump type" "bump_version reports the invalid bump type"
}

# --- Group B: release.sh end-to-end -----------------------------------------

test_release_happy_path() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot stamp manifests"
        return
    fi
    local sb rc=0
    make_full_sandbox sb
    bash "$sb/bin/release.sh" patch --non-interactive --skip-changelog --force \
        >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "release.sh patch --non-interactive --skip-changelog --force succeeds"
    assert_equals "1.2.4" "$(command cat "$sb/VERSION")" "VERSION bumped 1.2.3 → 1.2.4"
    assert_file_contains "$sb/plugins/dev-core/.claude-plugin/plugin.json" \
        '"version": "1.2.4"' "dev-core plugin.json stamped to 1.2.4"
}

test_release_missing_version_file() {
    local sb rc=0 err
    make_bin_sandbox sb
    command rm -f "$sb/VERSION"
    err="$(bash "$sb/bin/release.sh" patch --non-interactive --force 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "release.sh exits 1 when VERSION is missing"
    assert_contains "$err" "VERSION file not found" "release.sh reports the missing VERSION file"
}

test_release_invalid_version_arg() {
    local sb rc=0 err
    make_bin_sandbox sb
    err="$(bash "$sb/bin/release.sh" 1.2 --non-interactive --force 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "release.sh exits 1 on a malformed explicit version"
    assert_contains "$err" "invalid version format" "release.sh reports the bad version format"
}

test_release_same_version_without_force() {
    local sb rc=0 err
    make_bin_sandbox sb
    err="$(bash "$sb/bin/release.sh" 1.2.3 --non-interactive 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "release.sh refuses a no-op version without --force"
    assert_contains "$err" "already" "release.sh explains the version is unchanged"
}

test_release_no_args() {
    local sb rc=0 out
    make_bin_sandbox sb
    # usage() prints the help block to stdout (via cat), so capture both streams.
    out="$(bash "$sb/bin/release.sh" </dev/null 2>&1)" || rc=$?
    assert_exit 1 "$rc" "release.sh exits 1 with no version argument"
    assert_contains "$out" "Usage:" "release.sh prints usage with no version argument"
}

# --- Group C: generate-release-notes.sh -------------------------------------

# Drop a synthetic CHANGELOG.md at the sandbox root (the PROJECT_ROOT the script
# resolves relative to bin/).
seed_changelog() {
    command cat >"$1/CHANGELOG.md" <<'EOF'
# Changelog

## [9.9.9] - 2026-01-01

### Added

- SENTINEL_LINE_FOR_TEST a notable feature

## [9.9.8] - 2025-12-01

### Fixed

- an older fix
EOF
}

test_release_notes_missing_arg() {
    local sb rc=0 err
    make_bin_sandbox sb
    err="$(bash "$sb/bin/generate-release-notes.sh" </dev/null 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "generate-release-notes.sh exits 1 with no VERSION argument"
    assert_contains "$err" "Usage:" "generate-release-notes.sh prints usage with no argument"
}

test_release_notes_extracts_section() {
    local sb out
    make_bin_sandbox sb
    seed_changelog "$sb"
    out="$(bash "$sb/bin/generate-release-notes.sh" 9.9.9 2>/dev/null)"
    assert_contains "$out" "SENTINEL_LINE_FOR_TEST" "extracts the matching version section"
    # The next section's content must not bleed through.
    if [[ "$out" == *"an older fix"* ]]; then
        _fail "section extraction stops at the next header" "Leaked: 'an older fix'"
    fi
    # The fallback block must not appear when a real section was found.
    if [[ "$out" == *"See [CHANGELOG.md]"* ]]; then
        _fail "no fallback when a section matched" "Saw fallback marker"
    fi
}

test_release_notes_fallback_no_section() {
    local sb out
    make_bin_sandbox sb
    seed_changelog "$sb"
    out="$(bash "$sb/bin/generate-release-notes.sh" 0.0.0 2>/dev/null)"
    assert_contains "$out" "## Release v0.0.0" "fallback header for an absent version"
    assert_contains "$out" "claude plugin marketplace add" "fallback includes install instructions"
}

test_release_notes_fallback_no_changelog() {
    local sb out
    make_bin_sandbox sb
    command rm -f "$sb/CHANGELOG.md"
    out="$(bash "$sb/bin/generate-release-notes.sh" 1.0.0 2>/dev/null)"
    assert_contains "$out" "## Release v1.0.0" "fallback header when CHANGELOG.md is absent"
    assert_contains "$out" "claude plugin marketplace add" "fallback includes install instructions"
}

# --- Group D: git-automation.sh GitHub-release branch -----------------------
#
# perform_git_automation delegates the GitHub release to CI when the tag is
# pushed (release.yml signs + publishes), and only falls back to a local
# unsigned `gh release create` when a tag exists but was NOT pushed. These
# tests source the function directly and put stub `git`/`gh` on PATH so no real
# git or network calls happen; a stub `gh` records whether it was invoked.

# run_git_automation <sandbox> <AUTO_COMMIT> <AUTO_TAG> <AUTO_PUSH> <AUTO_GITHUB_RELEASE> [gh_mode] [git_push_rc]
# Sources git-automation.sh in a subshell with stubbed git/gh on PATH and runs
# perform_git_automation 9.9.9. Echoes combined stdout+stderr and preserves the
# function's exit code. The stub `gh` touches "$sandbox/gh_called" when invoked.
#   gh_mode:      "ok" (default) stub exits 0; "fail" stub exits 1 (release-create
#                 failure path); "missing" omits the gh stub AND shadows the real
#                 gh with a non-executable placeholder so `command -v gh` fails.
#   git_push_rc:  exit code the git stub returns for a `push` subcommand (default
#                 0). Non-zero exercises the push-failure `exit 1` paths.
# The stub dir is always kept on a full PATH (prepended), so the git/gh stubs
# shadow the real binaries while coreutils + generate-release-notes.sh still
# resolve — the git stub therefore genuinely runs in every mode.
run_git_automation() {
    local sb="$1" ac="$2" at="$3" ap="$4" agr="$5" gh_mode="${6:-ok}" push_rc="${7:-0}"
    local stub="$sb/stubbin"
    command mkdir -p "$stub"
    # git stub: `push` returns the caller-chosen code; every other subcommand
    # (commit/tag/...) succeeds. Absolute /bin/sh shebang so it runs regardless
    # of PATH contents.
    command cat >"$stub/git" <<EOF
#!/bin/sh
case "\$1" in
    push) exit $push_rc ;;
    *) exit 0 ;;
esac
EOF
    command chmod +x "$stub/git"
    command rm -f "$sb/gh_called"
    if [ "$gh_mode" = "ok" ] || [ "$gh_mode" = "fail" ]; then
        local gh_rc=0
        [ "$gh_mode" = "fail" ] && gh_rc=1
        command cat >"$stub/gh" <<EOF
#!/bin/sh
touch "$sb/gh_called"
exit $gh_rc
EOF
        command chmod +x "$stub/gh"
    fi
    # A .git marker so the function's early "not a git repository" guard passes.
    command mkdir -p "$sb/.git"
    (
        # ok/fail: stub prepended to a full PATH so the git/gh stubs shadow the
        # real binaries while coreutils + generate-release-notes.sh (used by the
        # unsigned fallback) still resolve.
        # missing: PATH = stub only, so there is NO gh anywhere and
        # `command -v gh` fails. The git stub's absolute /bin/sh shebang means it
        # still runs, and the gh-missing branch exits before any coreutil call.
        if [ "$gh_mode" = "missing" ]; then
            PATH="$stub"
        else
            PATH="$stub:$PATH"
        fi
        BIN_DIR="$sb/bin"
        GH_REPO="joshjhall/librarian"
        AUTO_COMMIT="$ac" AUTO_TAG="$at" AUTO_PUSH="$ap" AUTO_GITHUB_RELEASE="$agr"
        export PATH BIN_DIR GH_REPO AUTO_COMMIT AUTO_TAG AUTO_PUSH AUTO_GITHUB_RELEASE
        cd "$sb" || exit 1
        # shellcheck source=bin/lib/release/git-automation.sh
        source "$REPO_ROOT/bin/lib/release/git-automation.sh"
        perform_git_automation "9.9.9"
    ) 2>&1
}

test_git_automation_pushed_tag_defers_to_ci() {
    local sb out
    make_bin_sandbox sb
    out="$(run_git_automation "$sb" true true true true)"
    assert_contains "$out" "release.yml will publish the signed GitHub release" \
        "pushed tag defers to CI as the canonical signed publisher"
    assert_true "[ ! -e '$sb/gh_called' ]" "gh release create is NOT invoked when the tag was pushed"
}

test_git_automation_unpushed_tag_creates_unsigned() {
    local sb out
    make_bin_sandbox sb
    out="$(run_git_automation "$sb" true true false true)"
    assert_contains "$out" "UNSIGNED release" \
        "unpushed tag warns that the local release is unsigned"
    assert_true "[ -e '$sb/gh_called' ]" "gh release create IS invoked on the unpushed-tag fallback"
}

test_git_automation_no_tag_skips_release() {
    local sb out
    make_bin_sandbox sb
    # AUTO_TAG=false + AUTO_PUSH=false: no tag exists, so neither the CI-defer
    # nor the local fallback should create a release, and the manual-steps hint
    # should be emitted instead.
    out="$(run_git_automation "$sb" true false false true)"
    assert_true "[ ! -e '$sb/gh_called' ]" "no tag → gh release create is NOT invoked"
    assert_not_contains "$out" "release.yml will publish" "no tag → does not claim CI will publish"
    assert_contains "$out" "To complete the release" "manual-steps header emitted when not fully automated"
    assert_contains "$out" "git tag -a v9.9.9" "manual-steps lists the tag command"
}

test_git_automation_push_no_tag_skips_release() {
    local sb out
    make_bin_sandbox sb
    # AUTO_PUSH=true but AUTO_TAG=false: branch is pushed, but no tag exists, so
    # no release of any kind is created (distinct code path from no-push/no-tag).
    out="$(run_git_automation "$sb" true false true true)"
    assert_true "[ ! -e '$sb/gh_called' ]" "push without tag → gh release create is NOT invoked"
    assert_not_contains "$out" "release.yml will publish" "push without tag → no CI-defer message"
    assert_not_contains "$out" "UNSIGNED release" "push without tag → no unsigned-fallback message"
}

test_git_automation_release_disabled() {
    local sb out
    make_bin_sandbox sb
    out="$(run_git_automation "$sb" true true true false)"
    assert_true "[ ! -e '$sb/gh_called' ]" "AUTO_GITHUB_RELEASE=false → gh is NOT invoked"
    assert_not_contains "$out" "release.yml will publish" "AUTO_GITHUB_RELEASE=false → no CI-defer message"
}

test_git_automation_unpushed_tag_gh_missing_degrades() {
    local sb out
    make_bin_sandbox sb
    # gh unavailable on the fallback path: warn and continue (exit 0), do not crash.
    out="$(run_git_automation "$sb" true true false true missing)"
    assert_contains "$out" "gh CLI not found" "missing gh on the fallback path warns gracefully"
    assert_true "[ ! -e '$sb/gh_called' ]" "missing gh → no gh invocation recorded"
}

test_git_automation_gh_release_failure_degrades() {
    local sb out
    make_bin_sandbox sb
    # gh present but exits non-zero: warn + print the manual-create URL, no crash.
    out="$(run_git_automation "$sb" true true false true fail)"
    assert_contains "$out" "failed to create GitHub release" "gh failure warns gracefully"
    assert_contains "$out" "releases/new?tag=v9.9.9" "gh failure prints the manual-create URL"
}

test_git_automation_push_failure_aborts() {
    local sb out rc=0
    make_bin_sandbox sb
    # git push exits non-zero: the function must abort with exit 1 and report it,
    # rather than silently proceeding to tag/release.
    out="$(run_git_automation "$sb" true true true true ok 1)" || rc=$?
    assert_exit 1 "$rc" "a failed git push aborts perform_git_automation with exit 1"
    assert_contains "$out" "Failed to push branch" "push failure is reported"
    assert_true "[ ! -e '$sb/gh_called' ]" "push failure → no release is created"
}

test_git_automation_not_a_git_repo() {
    local sb out rc=0
    make_bin_sandbox sb
    # No .git marker: the early guard returns 0 without touching git/gh.
    command rm -rf "$sb/.git"
    out="$(
        cd "$sb" || exit 1
        BIN_DIR="$sb/bin" GH_REPO="joshjhall/librarian" \
            AUTO_COMMIT=true AUTO_TAG=true AUTO_PUSH=true AUTO_GITHUB_RELEASE=true \
            bash -c 'source "'"$REPO_ROOT"'/bin/lib/release/git-automation.sh"; perform_git_automation 9.9.9'
    )" || rc=$?
    assert_exit 0 "$rc" "missing .git returns 0 (manual commit required)"
    assert_contains "$out" "Not a git repository" "missing .git prints the guard message"
}

# --- Run all tests ----------------------------------------------------------

run_test test_is_semver_accepts_valid "is_semver accepts a valid X.Y.Z"
run_test test_is_semver_rejects_invalid "is_semver rejects non-X.Y.Z strings"
run_test test_bump_version_increments "bump_version increments major/minor/patch correctly"
run_test test_bump_version_rejects_bad_type "bump_version rejects an invalid bump type"

run_test test_release_happy_path "release.sh bumps VERSION and stamps manifests (--non-interactive --force)"
run_test test_release_missing_version_file "release.sh exits 1 when the VERSION file is missing"
run_test test_release_invalid_version_arg "release.sh exits 1 on a malformed explicit version"
run_test test_release_same_version_without_force "release.sh refuses a no-op bump without --force"
run_test test_release_no_args "release.sh exits 1 with usage when given no version"

run_test test_release_notes_missing_arg "generate-release-notes.sh exits 1 with usage on no argument"
run_test test_release_notes_extracts_section "generate-release-notes.sh extracts the matching CHANGELOG section"
run_test test_release_notes_fallback_no_section "generate-release-notes.sh falls back when the version section is absent"
run_test test_release_notes_fallback_no_changelog "generate-release-notes.sh falls back when CHANGELOG.md is absent"

run_test test_git_automation_pushed_tag_defers_to_ci "git-automation: pushed tag defers to release.yml (no local gh release)"
run_test test_git_automation_unpushed_tag_creates_unsigned "git-automation: unpushed tag creates an unsigned local release"
run_test test_git_automation_no_tag_skips_release "git-automation: no tag + no push creates no release, prints manual steps"
run_test test_git_automation_push_no_tag_skips_release "git-automation: push without tag creates no release"
run_test test_git_automation_release_disabled "git-automation: AUTO_GITHUB_RELEASE=false creates no release"
run_test test_git_automation_unpushed_tag_gh_missing_degrades "git-automation: missing gh on the fallback path degrades gracefully"
run_test test_git_automation_gh_release_failure_degrades "git-automation: a failing gh release create degrades gracefully"
run_test test_git_automation_push_failure_aborts "git-automation: a failed git push aborts with exit 1"
run_test test_git_automation_not_a_git_repo "git-automation: missing .git returns 0 with a manual-commit notice"

generate_report
