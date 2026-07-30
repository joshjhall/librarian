# shellcheck shell=bash
# Group C — generate-release-notes.sh — release toolchain tests (issue #564 split).
#
# Covers section extraction from CHANGELOG.md.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

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
