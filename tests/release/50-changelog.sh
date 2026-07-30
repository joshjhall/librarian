# shellcheck shell=bash
# Groups E and F — changelog.sh — release toolchain tests (issue #564 split).
#
# Covers the git-cliff branches and release.sh's call-site abort guard.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

# --- Group E: changelog.sh git-cliff branches -------------------------------
#
# generate_changelog (bin/lib/release/changelog.sh) has four branches that were
# previously unreachable by any test: --skip-changelog only ever exercised the
# first early-return (test_release_happy_path passes --skip-changelog), leaving
# the git-cliff invocation, the empty-render safety guard, and the MD012 trim
# uncovered. These source changelog.sh directly and drive each branch with a
# stubbed git-cliff on PATH (or an ensure_git_cliff override for the absent
# branch) — no node, no network, no sudo (issue #233).

# run_generate_changelog <sandbox> <skip> <cliff_mode>
#   skip:        "true"/"false" → SKIP_CHANGELOG
#   cliff_mode:  absent | runfail | empty | success (ignored when skip=true)
# Seeds a sentinel CHANGELOG.md, then runs generate_changelog 9.9.9 in a subshell
# cd'd into <sandbox> with a stub git-cliff on PATH (for runfail/empty/success)
# or ensure_git_cliff overridden to fail (for absent — avoids the real installer,
# which would try cargo/curl/sudo). Echoes combined stdout+stderr, preserves the
# exit code.
run_generate_changelog() {
    local sb="$1" skip="$2" mode="${3:-success}"
    local stub="$sb/stubbin"
    command mkdir -p "$stub"

    # git-cliff stub, per mode. Invoked as `git-cliff -o CHANGELOG.md --tag v9.9.9
    # --include-path '**/*'`; each writes CHANGELOG.md in cwd, then exits.
    case "$mode" in
        runfail)
            # Partial write, then failure (return 1, file not to be trusted).
            command cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 1
EOF
            command chmod +x "$stub/git-cliff"
            ;;
        empty)
            # Headerless render: no "## [version]" section, but exit 0 — the
            # silent-wipe hazard the empty-render guard must catch.
            command cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 0
EOF
            command chmod +x "$stub/git-cliff"
            ;;
        success)
            # Valid render WITH a version section and trailing blank lines, so the
            # MD012 trailing-blank trim is exercised too.
            command cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n\n## [9.9.9] - 2026-01-01\n\n### Added\n\n- SENTINEL_NEW\n\n\n\n' >CHANGELOG.md
exit 0
EOF
            command chmod +x "$stub/git-cliff"
            ;;
    esac

    # Sentinel so an "untouched" assertion is meaningful on the skip/absent paths.
    command printf 'SENTINEL_ORIGINAL\n' >"$sb/CHANGELOG.md"

    (
        PATH="$stub:$PATH"
        SKIP_CHANGELOG="$skip"
        export PATH SKIP_CHANGELOG
        cd "$sb" || exit 1
        if [ "$mode" = "absent" ]; then
            # Force the git-cliff-unavailable branch regardless of a real
            # git-cliff on the host PATH, without invoking the real installer.
            # This is the only symbol changelog.sh needs from git-cliff.sh.
            ensure_git_cliff() { return 1; }
        else
            # shellcheck source=bin/lib/release/git-cliff.sh
            source "$REPO_ROOT/bin/lib/release/git-cliff.sh"
        fi
        # shellcheck source=bin/lib/release/changelog.sh
        source "$REPO_ROOT/bin/lib/release/changelog.sh"
        generate_changelog "9.9.9"
    ) 2>&1
}

test_changelog_skip_leaves_file_untouched() {
    local sb out rc=0
    make_bin_sandbox sb
    out="$(run_generate_changelog "$sb" true success)" || rc=$?
    assert_exit 0 "$rc" "generate_changelog returns 0 when SKIP_CHANGELOG=true"
    assert_contains "$out" "Skipping CHANGELOG generation" "the skip path announces itself"
    assert_file_contains "$sb/CHANGELOG.md" "SENTINEL_ORIGINAL" "skip leaves CHANGELOG.md untouched"
}

test_changelog_git_cliff_absent_returns_1_untouched() {
    local sb out rc=0
    make_bin_sandbox sb
    out="$(run_generate_changelog "$sb" false absent)" || rc=$?
    assert_exit 1 "$rc" "git-cliff unavailable → generate_changelog returns 1"
    assert_contains "$out" "git-cliff unavailable" "the absent path warns"
    assert_file_contains "$sb/CHANGELOG.md" "SENTINEL_ORIGINAL" "absent leaves CHANGELOG.md untouched"
}

test_changelog_git_cliff_runfail_returns_1() {
    local sb out rc=0
    make_bin_sandbox sb
    out="$(run_generate_changelog "$sb" false runfail)" || rc=$?
    assert_exit 1 "$rc" "a git-cliff run failure → generate_changelog returns 1"
    assert_contains "$out" "failed to generate CHANGELOG.md" "the run-failure path warns"
}

test_changelog_empty_render_refuses() {
    local sb out rc=0
    make_bin_sandbox sb
    out="$(run_generate_changelog "$sb" false empty)" || rc=$?
    assert_exit 1 "$rc" "a headerless render → generate_changelog returns 1"
    assert_contains "$out" "has no [9.9.9] section" "the empty-render guard fires"
    assert_contains "$out" "refusing to wipe history" "the empty-render guard explains the refusal"
}

test_changelog_success_trims_trailing_blanks() {
    local sb out rc=0
    make_bin_sandbox sb
    out="$(run_generate_changelog "$sb" false success)" || rc=$?
    assert_exit 0 "$rc" "a valid render → generate_changelog returns 0"
    assert_contains "$out" "Generated CHANGELOG.md" "the success path announces completion"
    assert_file_contains "$sb/CHANGELOG.md" "## \[9.9.9\]" "the new version's section is present"
    # MD012: trailing blank lines trimmed → the last line is the final content line.
    assert_equals "- SENTINEL_NEW" "$(command tail -n 1 "$sb/CHANGELOG.md")" "trailing blank lines are trimmed"
}

# --- Group F: release.sh call-site abort guard (finding #1) ------------------
#
# A non-zero generate_changelog must HARD-ABORT release.sh before any
# auto-commit/tag/push, but stay tolerant in a purely interactive prepare. These
# drive the full release.sh (node-gated) with a git-cliff stub forced to fail.

# seed_failing_git_cliff <sandbox> — writes a git-cliff stub that partial-writes
# then exits 1 into <sandbox>/stubbin, and echoes that stub dir for PATH.
seed_failing_git_cliff() {
    local sb="$1"
    local stub="$sb/stubbin"
    command mkdir -p "$stub"
    command cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 1
EOF
    command chmod +x "$stub/git-cliff"
    printf '%s' "$stub"
}

test_release_changelog_failure_aborts_under_auto_commit() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot stamp manifests"
        return
    fi
    local sb stub out rc=0
    make_full_sandbox sb
    stub="$(seed_failing_git_cliff "$sb")"
    out="$(PATH="$stub:$PATH" bash "$sb/bin/release.sh" patch \
        --non-interactive --force --auto-commit 2>&1)" || rc=$?
    assert_exit 1 "$rc" "release.sh aborts (exit 1) when git-cliff fails under --auto-commit"
    assert_contains "$out" "refusing to commit/tag/push" "the abort explains the refusal"
    assert_not_contains "$out" "Release 1.2.4 prepared" "aborts before the prepared banner / git automation"
}

test_release_changelog_failure_aborts_under_auto_tag() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot stamp manifests"
        return
    fi
    local sb stub out rc=0
    make_full_sandbox sb
    stub="$(seed_failing_git_cliff "$sb")"
    # --auto-tag alone (AUTO_COMMIT=false, AUTO_PUSH=false) exercises a SECOND,
    # independent leg of the guard's three-way OR — so dropping the AUTO_TAG
    # check would be caught here even though the --auto-commit test still passes.
    out="$(PATH="$stub:$PATH" bash "$sb/bin/release.sh" patch \
        --non-interactive --force --auto-tag 2>&1)" || rc=$?
    assert_exit 1 "$rc" "release.sh aborts (exit 1) when git-cliff fails under --auto-tag"
    assert_contains "$out" "refusing to commit/tag/push" "the abort explains the refusal"
    assert_not_contains "$out" "Release 1.2.4 prepared" "aborts before the prepared banner / git automation"
}

test_release_changelog_failure_tolerated_without_auto() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot stamp manifests"
        return
    fi
    local sb stub out rc=0
    make_full_sandbox sb
    stub="$(seed_failing_git_cliff "$sb")"
    out="$(PATH="$stub:$PATH" bash "$sb/bin/release.sh" patch \
        --non-interactive --force 2>&1)" || rc=$?
    assert_exit 0 "$rc" "release.sh tolerates a git-cliff failure in a non-automated prepare"
    assert_contains "$out" "failed to generate CHANGELOG.md" "the changelog failure is still surfaced"
    assert_contains "$out" "Release 1.2.4 prepared" "the interactive prepare still completes"
    # The summary must NOT claim CHANGELOG.md was updated when generation failed,
    # and must warn the operator to inspect it before committing.
    assert_contains "$out" "inspect CHANGELOG.md before committing" "a failed changelog is flagged for inspection"
    assert_not_contains "$out" ", CHANGELOG.md" "the Updated: summary omits CHANGELOG.md on a failed generation"
}
