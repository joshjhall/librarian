# shellcheck shell=bash
# Group D — git-automation.sh — release toolchain tests (issue #564 split).
#
# Covers the GitHub-release branch, including the deliberate skip that stops an unsigned release racing CI.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

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
    command mkdir -p "$stub"
    # git stub: a `push` subcommand returns a per-ref code so the branch push
    # (`push origin <branch>`) and the tag push (`push origin v<tag>`) can fail
    # independently — the pushed ref is $3, and a tag ref is the only one that
    # starts with `v`. Every other subcommand (commit/tag/rev-parse/...) succeeds.
    # Absolute /bin/sh shebang so it runs regardless of PATH contents.
    command cat >"$stub/git" <<EOF
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
    command chmod +x "$stub/git"
    # mktemp stub: delegates to the real mktemp but also records the created path
    # to "$sb/notes_tempfile_path" so a test can assert the unsigned-fallback
    # subshell's EXIT trap actually removed the release-notes temp file.
    # git-automation.sh creates it via `command mktemp`, which honors PATH — and
    # this stub named `mktemp` is on that PATH, so the stub must delegate to the
    # REAL mktemp by its resolved absolute path (captured before the stub shadows
    # PATH); a `command mktemp` inside the stub would recurse into the stub.
    local real_mktemp
    real_mktemp="$(command -v mktemp)"
    command cat >"$stub/mktemp" <<EOF
#!/bin/sh
f="\$("$real_mktemp" "\$@")" || exit 1
printf '%s\n' "\$f" >"$sb/notes_tempfile_path"
printf '%s\n' "\$f"
EOF
    command chmod +x "$stub/mktemp"
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
    notes_file="$(command cat "$sb/notes_tempfile_path" 2>/dev/null)"
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
