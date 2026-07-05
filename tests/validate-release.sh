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
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# make_bin_sandbox <varname>
# Creates a fresh sandbox subdir with a copy of bin/ and a synthetic VERSION
# (1.2.3), and assigns its path to the caller's named variable. Enough for
# release.sh's pre-node error paths and for generate-release-notes.sh (which
# sources nothing).
make_bin_sandbox() {
    local __out="$1"
    local dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/cp -R "$REPO_ROOT/bin" "$dir/bin"
    /usr/bin/printf '1.2.3\n' >"$dir/VERSION"
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
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/cp -R "$REPO_ROOT/bin" "$dir/bin"
    /usr/bin/mkdir -p "$dir/tests"
    /usr/bin/cp "$REPO_ROOT/tests/validate-manifests.mjs" "$dir/tests/"
    /usr/bin/cp -R "$REPO_ROOT/.claude-plugin" "$dir/.claude-plugin"
    /usr/bin/cp -R "$REPO_ROOT/plugins" "$dir/plugins"
    /usr/bin/printf '1.2.3\n' >"$dir/VERSION"
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
    assert_equals "1.2.4" "$(/usr/bin/cat "$sb/VERSION")" "VERSION bumped 1.2.3 → 1.2.4"
    assert_file_contains "$sb/plugins/dev-core/.claude-plugin/plugin.json" \
        '"version": "1.2.4"' "dev-core plugin.json stamped to 1.2.4"
}

test_release_missing_version_file() {
    local sb rc=0 err
    make_bin_sandbox sb
    /usr/bin/rm -f "$sb/VERSION"
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
    /usr/bin/cat >"$1/CHANGELOG.md" <<'EOF'
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
    /usr/bin/rm -f "$sb/CHANGELOG.md"
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
#   git_push_rc:  exit code the git stub returns for a BRANCH `push` subcommand
#                 (`git push origin <branch>`, default 0). Non-zero exercises the
#                 branch-push-failure `exit 1` path.
#   tag_push_rc:  exit code the git stub returns for a TAG `push` subcommand
#                 (`git push origin v<tag>`, default = git_push_rc). Set it to 1
#                 with git_push_rc=0 to exercise the tag-push-failure `exit 1`
#                 path without tripping the branch-push guard first.
# The stub dir is always kept on a full PATH (prepended), so the git/gh stubs
# shadow the real binaries while coreutils + generate-release-notes.sh still
# resolve — the git stub therefore genuinely runs in every mode.
run_git_automation() {
    local sb="$1" ac="$2" at="$3" ap="$4" agr="$5" gh_mode="${6:-ok}" push_rc="${7:-0}"
    local tag_push_rc="${8:-$push_rc}"
    local stub="$sb/stubbin"
    /usr/bin/mkdir -p "$stub"
    # git stub: a `push` subcommand returns a per-ref code so the branch push
    # (`push origin <branch>`) and the tag push (`push origin v<tag>`) can fail
    # independently — the pushed ref is $3, and a tag ref is the only one that
    # starts with `v`. Every other subcommand (commit/tag/rev-parse/...) succeeds.
    # Absolute /bin/sh shebang so it runs regardless of PATH contents.
    /usr/bin/cat >"$stub/git" <<EOF
#!/bin/sh
case "\$1" in
    push)
        case "\$3" in
            v*) exit $tag_push_rc ;;
            *) exit $push_rc ;;
        esac ;;
    *) exit 0 ;;
esac
EOF
    /usr/bin/chmod +x "$stub/git"
    # mktemp stub: delegates to the real mktemp but also records the created path
    # to "$sb/notes_tempfile_path" so a test can assert the unsigned-fallback
    # subshell's EXIT trap actually removed the release-notes temp file.
    # git-automation.sh creates it via `command mktemp`, which honors PATH.
    /usr/bin/cat >"$stub/mktemp" <<EOF
#!/bin/sh
f="\$(/usr/bin/mktemp "\$@")" || exit 1
printf '%s\n' "\$f" >"$sb/notes_tempfile_path"
printf '%s\n' "\$f"
EOF
    /usr/bin/chmod +x "$stub/mktemp"
    /usr/bin/rm -f "$sb/gh_called"
    if [ "$gh_mode" = "ok" ] || [ "$gh_mode" = "fail" ]; then
        local gh_rc=0
        [ "$gh_mode" = "fail" ] && gh_rc=1
        /usr/bin/cat >"$stub/gh" <<EOF
#!/bin/sh
touch "$sb/gh_called"
exit $gh_rc
EOF
        /usr/bin/chmod +x "$stub/gh"
    fi
    # A .git marker so the function's early "not a git repository" guard passes.
    /usr/bin/mkdir -p "$sb/.git"
    (
        # ok/fail: stub prepended to a full PATH so the git/gh stubs shadow the
        # real binaries while coreutils + generate-release-notes.sh (used by the
        # unsigned fallback) still resolve.
        # missing: PATH = stub only, so there is NO gh anywhere and
        # `command -v gh` fails. The git stub's absolute /bin/sh shebang means it
        # still runs, and the gh-missing branch exits before any coreutils call.
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
    # The unsigned-fallback subshell's `trap ... EXIT` must remove the release-
    # notes temp file even when gh fails. The mktemp stub recorded the path; if
    # the trap (or the subshell) regressed, the file would still be present here.
    local notes_file
    notes_file="$(/usr/bin/cat "$sb/notes_tempfile_path" 2>/dev/null)"
    assert_true "[ -n '$notes_file' ]" "the fallback path created a release-notes temp file"
    assert_true "[ ! -e '$notes_file' ]" "the subshell EXIT trap removed the release-notes temp file"
}

test_git_automation_tag_push_failure_aborts() {
    local sb out rc=0
    make_bin_sandbox sb
    # Branch push succeeds (push_rc=0) but the TAG push fails (tag_push_rc=1):
    # the function must reach the tag-push guard and abort with exit 1, rather
    # than proceeding to a release. Distinct code path from the branch-push
    # failure above, which trips first when both share one push_rc.
    out="$(run_git_automation "$sb" true true true true ok 0 1)" || rc=$?
    assert_exit 1 "$rc" "a failed tag push aborts perform_git_automation with exit 1"
    assert_contains "$out" "Failed to push tag" "tag-push failure is reported"
    assert_true "[ ! -e '$sb/gh_called' ]" "tag-push failure → no release is created"
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
    /usr/bin/rm -rf "$sb/.git"
    out="$(
        cd "$sb" || exit 1
        BIN_DIR="$sb/bin" GH_REPO="joshjhall/librarian" \
            AUTO_COMMIT=true AUTO_TAG=true AUTO_PUSH=true AUTO_GITHUB_RELEASE=true \
            bash -c 'source "'"$REPO_ROOT"'/bin/lib/release/git-automation.sh"; perform_git_automation 9.9.9'
    )" || rc=$?
    assert_exit 0 "$rc" "missing .git returns 0 (manual commit required)"
    assert_contains "$out" "Not a git repository" "missing .git prints the guard message"
}

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
    /usr/bin/mkdir -p "$stub"

    # git-cliff stub, per mode. Invoked as `git-cliff -o CHANGELOG.md --tag v9.9.9
    # --include-path '**/*'`; each writes CHANGELOG.md in cwd, then exits.
    case "$mode" in
        runfail)
            # Partial write, then failure (return 1, file not to be trusted).
            /usr/bin/cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 1
EOF
            /usr/bin/chmod +x "$stub/git-cliff"
            ;;
        empty)
            # Headerless render: no "## [version]" section, but exit 0 — the
            # silent-wipe hazard the empty-render guard must catch.
            /usr/bin/cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 0
EOF
            /usr/bin/chmod +x "$stub/git-cliff"
            ;;
        success)
            # Valid render WITH a version section and trailing blank lines, so the
            # MD012 trailing-blank trim is exercised too.
            /usr/bin/cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n\n## [9.9.9] - 2026-01-01\n\n### Added\n\n- SENTINEL_NEW\n\n\n\n' >CHANGELOG.md
exit 0
EOF
            /usr/bin/chmod +x "$stub/git-cliff"
            ;;
    esac

    # Sentinel so an "untouched" assertion is meaningful on the skip/absent paths.
    /usr/bin/printf 'SENTINEL_ORIGINAL\n' >"$sb/CHANGELOG.md"

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
    assert_equals "- SENTINEL_NEW" "$(/usr/bin/tail -n 1 "$sb/CHANGELOG.md")" "trailing blank lines are trimmed"
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
    /usr/bin/mkdir -p "$stub"
    /usr/bin/cat >"$stub/git-cliff" <<'EOF'
#!/bin/sh
printf '# Changelog\n' >CHANGELOG.md
exit 1
EOF
    /usr/bin/chmod +x "$stub/git-cliff"
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
run_test test_git_automation_push_failure_aborts "git-automation: a failed branch push aborts with exit 1"
run_test test_git_automation_tag_push_failure_aborts "git-automation: a failed tag push aborts with exit 1"
run_test test_git_automation_not_a_git_repo "git-automation: missing .git returns 0 with a manual-commit notice"

run_test test_changelog_skip_leaves_file_untouched "changelog: --skip-changelog returns 0 and leaves CHANGELOG.md untouched"
run_test test_changelog_git_cliff_absent_returns_1_untouched "changelog: git-cliff unavailable returns 1 and leaves CHANGELOG.md untouched"
run_test test_changelog_git_cliff_runfail_returns_1 "changelog: a git-cliff run failure returns 1"
run_test test_changelog_empty_render_refuses "changelog: a headerless render is refused by the empty-render guard"
run_test test_changelog_success_trims_trailing_blanks "changelog: a valid render succeeds and trims trailing blank lines"

run_test test_release_changelog_failure_aborts_under_auto_commit "release.sh: a changelog failure aborts under --auto-commit"
run_test test_release_changelog_failure_aborts_under_auto_tag "release.sh: a changelog failure aborts under --auto-tag (second OR leg)"
run_test test_release_changelog_failure_tolerated_without_auto "release.sh: a changelog failure is tolerated without auto flags"

generate_report
