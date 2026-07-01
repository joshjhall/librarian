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

# run_git_automation <sandbox> <AUTO_COMMIT> <AUTO_TAG> <AUTO_PUSH> <AUTO_GITHUB_RELEASE> [gh_available]
# Sources git-automation.sh in a subshell with stubbed git/gh on PATH and runs
# perform_git_automation 9.9.9. Echoes combined stdout+stderr; the stub `gh`
# touches "$sandbox/gh_called" when invoked. gh_available=false omits the gh
# stub AND masks the real gh (PATH is the stub dir only) so `command -v gh`
# fails — exercising the graceful-degradation branch.
run_git_automation() {
    local sb="$1" ac="$2" at="$3" ap="$4" agr="$5" gh_ok="${6:-true}"
    local stub="$sb/stubbin"
    command mkdir -p "$stub"
    # git stub: swallow every subcommand (commit/tag/push) as a success.
    command cat >"$stub/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    command rm -f "$sb/gh_called"
    if [ "$gh_ok" = "true" ]; then
        command cat >"$stub/gh" <<EOF
#!/usr/bin/env bash
command touch "$sb/gh_called"
exit 0
EOF
        command chmod +x "$stub/gh"
    fi
    command chmod +x "$stub/git"
    # A .git marker so the function's early "not a git repository" guard passes.
    # Created here (before the restricted-PATH subshell) with an absolute mkdir.
    command mkdir -p "$sb/.git"
    (
        # gh present: prepend the stub so the stub git/gh shadow the real ones,
        # keeping the rest of PATH for the coreutils + generate-release-notes.sh
        # the unsigned fallback runs.
        # gh missing: PATH = stub only (git stub, no gh), so `command -v gh`
        # fails. That branch reaches only shell builtins (`command echo`) plus
        # the git stub before returning, so it needs nothing else on PATH.
        if [ "$gh_ok" = "true" ]; then
            PATH="$stub:$PATH"
        else
            PATH="$stub"
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
    # AUTO_TAG=false: no tag exists, so neither the CI-defer nor the local
    # fallback should create a release (gh must not be called).
    out="$(run_git_automation "$sb" true false false true)"
    assert_true "[ ! -e '$sb/gh_called' ]" "no tag → gh release create is NOT invoked"
    assert_not_contains "$out" "release.yml will publish" "no tag → does not claim CI will publish"
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
    out="$(run_git_automation "$sb" true true false true false)"
    assert_contains "$out" "gh CLI not found" "missing gh on the fallback path warns gracefully"
    assert_true "[ ! -e '$sb/gh_called' ]" "missing gh → no gh invocation recorded"
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
run_test test_git_automation_no_tag_skips_release "git-automation: AUTO_TAG=false creates no release"
run_test test_git_automation_release_disabled "git-automation: AUTO_GITHUB_RELEASE=false creates no release"
run_test test_git_automation_unpushed_tag_gh_missing_degrades "git-automation: missing gh on the fallback path degrades gracefully"

generate_report
