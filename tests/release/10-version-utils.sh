# shellcheck shell=bash
# Group A — version-utils.sh — release toolchain tests (issue #564 split).
#
# Covers the semver validator and the bump arithmetic.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

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
