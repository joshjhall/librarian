#!/usr/bin/env bash
# Behavioral coverage for bin/apt-install.sh (#983).
#
# Companion to tests/lint-apt-hardening.sh, which checks only that the workflows
# ROUTE through the script. This suite checks that what they route to actually
# does the thing: disables the runner image's bundled third-party apt sources
# before updating, and constructs an install command carrying the retry option
# and every requested package.
#
# HOW IT RUNS UNPRIVILEGED. Two env overrides exist for this suite:
# APT_SOURCES_LIST_D points the disable step at a sandbox directory, and
# APT_INSTALL_SKIP_APT=1 prints the constructed apt-get commands instead of
# running them. The renames then happen for real, on actual files in the
# sandbox, with no root and without touching the host's apt.
#
# "Unprivileged" is a real claim here, not a comment. The script decides whether
# to prefix `mv` with sudo from whether the sources DIRECTORY is writable, not
# from `id -u` — so against a sandbox this suite owns, no sudo is invoked at
# all. That distinction is what keeps `just test` from stopping at an
# interactive password prompt on a machine without passwordless sudo (macOS is
# the repo's stated second target). Verify it by putting a failing `sudo` first
# on PATH and re-running: the renames must still succeed.
#
# WHAT SKIPPING APT CANNOT COVER, stated plainly rather than implied: whether
# apt itself then succeeds. That is the AC3 live-run evidence, captured in
# docs/verification/apt-hardening-e2e-983.md from the PR's own CI run. This
# suite covers the decision, not the download.
#
# Pure bash + coreutils. bash-3.2 clean and BSD-clean per CLAUDE.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APT_INSTALL="$REPO_ROOT/bin/apt-install.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "apt-install.sh (#983)"

SANDBOX_ROOT=""
cleanup() {
    [ -n "$SANDBOX_ROOT" ] && [ -d "$SANDBOX_ROOT" ] && command rm -rf "$SANDBOX_ROOT"
    return 0
}
trap cleanup EXIT

# new_sources_dir — create a fresh sandbox sources.list.d and echo its path.
# Each test gets its own so a rename in one cannot leak into another.
new_sources_dir() {
    local d
    d="$(command mktemp -d "$SANDBOX_ROOT/srcXXXXXX")"
    command printf '%s\n' "$d"
}

# run_installer <sources-dir> <args...> — run the script with the apt-get calls skipped, against
# the given sandbox, setting LAST_OUT and LAST_STATUS in the CALLER's shell.
#
# Deliberately not `out="$(run_installer ...)"`: a command substitution runs in a
# subshell, so a status assigned inside it is discarded and every exit-code
# assertion would read the initialised value instead — passing vacuously whatever
# the script did. Redirecting to a sandbox file and reading it back keeps both
# the output and the status in this shell.
LAST_STATUS=0
LAST_OUT=""
run_installer() {
    local dir="$1"
    shift
    local outfile="$SANDBOX_ROOT/out.$$"
    set +e
    APT_SOURCES_LIST_D="$dir" APT_INSTALL_SKIP_APT=1 \
        bash "$APT_INSTALL" "$@" >"$outfile" 2>&1
    LAST_STATUS=$?
    set -e
    LAST_OUT="$(command cat "$outfile")"
    command rm -f "$outfile"
}

# --- Source disabling ---------------------------------------------------------

test_disables_list_file() {
    local dir out
    dir="$(new_sources_dir)"
    command printf 'deb https://dl.google.com/linux/chrome-stable/deb stable main\n' \
        >"$dir/google-chrome.list"

    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_equals "0" "$LAST_STATUS" "Exits 0 on the happy path"
    assert_file_exists "$dir/google-chrome.list.disabled" \
        "A .list source is renamed aside to .disabled"
    assert_contains "$out" "disabled 1 third-party source(s)" \
        "Reports the count it disabled"
    # The original must be GONE, not merely copied — apt reads the directory, so
    # a leftover .list would still be fetched and could still fail the update.
    local original_gone=1
    [ -f "$dir/google-chrome.list" ] && original_gone=0
    assert_equals "1" "$original_gone" "The original .list no longer exists"
}

# deb822 is apt's newer source format and the runner image uses it too; a fix
# that only handled .list would leave those sources armed.
test_disables_sources_file() {
    local dir
    dir="$(new_sources_dir)"
    command printf 'Types: deb\nURIs: https://example.invalid/\n' >"$dir/vendor.sources"

    run_installer "$dir" jq

    assert_file_exists "$dir/vendor.sources.disabled" \
        "A deb822 .sources source is also disabled"
}

test_disables_every_source() {
    local dir out
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"
    command printf 'deb https://b.invalid/ stable main\n' >"$dir/b.list"
    command printf 'Types: deb\n' >"$dir/c.sources"

    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_contains "$out" "disabled 3 third-party source(s)" \
        "All bundled sources are disabled, not just a named one"
}

test_empty_dir_is_not_an_error() {
    local dir out
    dir="$(new_sources_dir)"

    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_equals "0" "$LAST_STATUS" "An empty sources.list.d is not an error"
    assert_contains "$out" "disabled 0 third-party source(s)" \
        "Reports zero rather than failing"
}

test_missing_dir_is_not_an_error() {
    local dir out
    dir="$SANDBOX_ROOT/definitely-not-created"

    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_equals "0" "$LAST_STATUS" "A missing sources.list.d is not an error"
    assert_contains "$out" "disabled 0 third-party source(s)" \
        "Reports zero for a missing directory"
}

# A workflow may install in more than one step, and a re-run of a job re-executes
# the same step; neither must fail on already-disabled sources.
test_rerun_is_idempotent() {
    local dir out
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"

    run_installer "$dir" jq
    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_equals "0" "$LAST_STATUS" "A second run exits 0"
    assert_contains "$out" "disabled 0 third-party source(s)" \
        "An already-.disabled source is left alone on re-run"
    local double_disabled=0
    [ -f "$dir/a.list.disabled.disabled" ] && double_disabled=1
    assert_equals "0" "$double_disabled" "No .disabled.disabled double-rename"
}

# --- Constructed command ------------------------------------------------------

test_command_carries_retries() {
    local dir out
    dir="$(new_sources_dir)"

    run_installer "$dir" jq shellcheck
    out="$LAST_OUT"

    assert_contains "$out" "Acquire::Retries=3" \
        "The retry option is passed to apt-get"
    assert_contains "$out" "apt-get -o Acquire::Retries=3 update" \
        "update carries the retry option"
    assert_contains "$out" "install -y jq shellcheck" \
        "Every requested package reaches the install command"
}

test_multiple_packages_preserved() {
    local dir out
    dir="$(new_sources_dir)"

    run_installer "$dir" alpha beta gamma
    out="$LAST_OUT"

    assert_contains "$out" "install -y alpha beta gamma" \
        "All three package arguments are preserved in order"
}

# --- Usage errors -------------------------------------------------------------
# Fail loud, never a silent no-op install that leaves a later gate skipping for a
# missing tool (CLAUDE.md § Runtime policy).

test_no_packages_is_an_error() {
    local dir out
    dir="$(new_sources_dir)"

    run_installer "$dir"
    out="$LAST_OUT"

    assert_equals "1" "$LAST_STATUS" "No package arguments exits non-zero"
    assert_contains "$out" "at least one package name" \
        "The error message is actionable"
}

# The claim the header makes, asserted rather than asserted-in-prose: against a
# directory we own, the rename must not go through sudo. Pinned with a failing
# `sudo` shim first on PATH — if the script ever reverts to deciding from
# `id -u`, this fails here instead of hanging a contributor's `just test` on a
# password prompt.
test_rename_does_not_invoke_sudo() {
    local dir shim
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"
    shim="$(command mktemp -d "$SANDBOX_ROOT/shimXXXXXX")"
    command printf '#!/bin/sh\nexit 99\n' >"$shim/sudo"
    command chmod +x "$shim/sudo"

    local outfile="$SANDBOX_ROOT/sudoprobe.$$"
    set +e
    PATH="$shim:$PATH" APT_SOURCES_LIST_D="$dir" APT_INSTALL_SKIP_APT=1 \
        bash "$APT_INSTALL" jq >"$outfile" 2>&1
    local status=$?
    set -e
    command rm -f "$outfile"

    assert_equals "0" "$status" "Exits 0 with a failing sudo on PATH"
    assert_file_exists "$dir/a.list.disabled" \
        "The rename succeeds without invoking sudo on a directory we own"
}

test_script_is_executable_shell() {
    assert_file_exists "$APT_INSTALL" "bin/apt-install.sh exists"
    assert_true "bash -n '$APT_INSTALL'" "The script parses as valid bash"
}

SANDBOX_ROOT="$(command mktemp -d)" || {
    command printf 'FATAL: mktemp -d failed; cannot run apt-install tests\n' >&2
    exit 1
}

run_test test_script_is_executable_shell "Script exists and parses"
run_test test_disables_list_file "A .list third-party source is disabled"
run_test test_disables_sources_file "A deb822 .sources source is disabled"
run_test test_disables_every_source "Every bundled source is disabled, not one by name"
run_test test_empty_dir_is_not_an_error "An empty sources.list.d is tolerated"
run_test test_missing_dir_is_not_an_error "A missing sources.list.d is tolerated"
run_test test_rerun_is_idempotent "Re-running does not re-disable or double-rename"
run_test test_command_carries_retries "apt-get carries Acquire::Retries=3 and the packages"
run_test test_multiple_packages_preserved "Multiple package arguments are preserved"
run_test test_no_packages_is_an_error "No packages fails loud with a usage error"
run_test test_rename_does_not_invoke_sudo "A sandbox rename does not shell out to sudo"

generate_report
