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
# the repo's stated second target). Both branches of that decision are pinned
# below, through APT_INSTALL_SUDO rather than a PATH shim — see the note on
# test_rename_does_not_invoke_sudo for why PATH cannot be trusted here.
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

# Ubuntu's OWN archive must survive the sweep. On 24.04 the main archive moved
# out of /etc/apt/sources.list into a deb822 file in this very directory, so
# "disable everything here" leaves apt with no sources at all.
#
# This is not hypothetical: the first live CI run of this script disabled
# ubuntu.sources alongside microsoft-prod and google-chrome, and still went green
# — because jq and shellcheck were already on the image. The first package that
# genuinely needed downloading would have failed, pointing nowhere near the
# cause. This suite could not have caught it, because a sandbox directory has no
# ubuntu.sources in it unless a test puts one there. So: put one there.
test_keeps_ubuntu_own_sources() {
    local dir out
    dir="$(new_sources_dir)"
    command printf 'Types: deb\nURIs: http://azure.archive.ubuntu.com/ubuntu/\n' \
        >"$dir/ubuntu.sources"
    command printf 'deb https://dl.google.com/linux/chrome/deb stable main\n' \
        >"$dir/google-chrome.sources"
    command printf 'deb https://packages.microsoft.com/ubuntu prod main\n' \
        >"$dir/microsoft-prod.list"

    run_installer "$dir" jq
    out="$LAST_OUT"

    assert_file_exists "$dir/ubuntu.sources" \
        "Ubuntu's own archive is NOT disabled"
    assert_file_exists "$dir/google-chrome.sources.disabled" \
        "The third-party Chrome source IS disabled"
    assert_file_exists "$dir/microsoft-prod.list.disabled" \
        "The third-party Microsoft source IS disabled"
    assert_contains "$out" "disabled 2 third-party source(s)" \
        "Only the two third-party sources are counted"
    assert_contains "$out" "keeping Ubuntu source" \
        "The kept source is reported rather than silently skipped"
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

# The claim the header makes, asserted rather than left as prose: against a
# directory we own, the rename must not go through sudo at all.
#
# Asserted via APT_INSTALL_SUDO rather than a PATH shim. This repo's devcontainer
# sets BASH_ENV=/etc/bash_env, which re-derives PATH for every non-interactive
# bash — so a `PATH="$shim:$PATH"` assertion resolves the REAL sudo and passes no
# matter what the script does. A first draft of this test did exactly that and
# proved nothing; injecting the command name is immune to how PATH is rebuilt.
test_rename_does_not_invoke_sudo() {
    local dir marker
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"
    marker="$SANDBOX_ROOT/nosudo-marker.$$"

    local outfile="$SANDBOX_ROOT/sudoprobe.$$"
    set +e
    APT_SOURCES_LIST_D="$dir" APT_INSTALL_SKIP_APT=1 \
        APT_INSTALL_SUDO="$MARKER_SUDO" MARKER_FILE="$marker" \
        bash "$APT_INSTALL" jq >"$outfile" 2>&1
    local status=$?
    set -e
    command rm -f "$outfile"

    assert_equals "0" "$status" "Exits 0 against a directory we own"
    assert_file_exists "$dir/a.list.disabled" "The rename still happens"
    local sudo_used=0
    [ -f "$marker" ] && sudo_used=1
    command rm -f "$marker"
    assert_equals "0" "$sudo_used" \
        "Elevation is NOT reached for a directory we own"
}

# The OTHER half of the predicate, and the one that matters in production:
# /etc/apt/sources.list.d on a runner is root-owned, so the rename MUST still
# elevate there. Without this, inverting or dropping the predicate would leave
# the suite green while CI began failing with "failed to disable apt source".
test_rename_invokes_sudo_when_dir_unwritable() {
    local dir marker
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"
    marker="$SANDBOX_ROOT/sudo-marker.$$"
    # Make the directory unwritable so the predicate must choose elevation. The
    # marker command re-opens it and then performs the rename, standing in for
    # what real sudo would achieve.
    command chmod 555 "$dir"

    # `-w` consults access(2), which grants root write permission regardless of
    # the mode bits — so as root the chmod above does not make the directory
    # unwritable and this test would assert the opposite of what it means. Skip
    # with a diagnosis rather than fail, or (worse) pass vacuously.
    if [ -w "$dir" ]; then
        command chmod 755 "$dir"
        skip_test "running as root (uid $(command id -u)); -w ignores mode bits"
        return 0
    fi

    local outfile="$SANDBOX_ROOT/sudoreq.$$"
    set +e
    APT_SOURCES_LIST_D="$dir" APT_INSTALL_SKIP_APT=1 \
        APT_INSTALL_SUDO="$MARKER_SUDO" MARKER_FILE="$marker" TARGET_DIR="$dir" \
        bash "$APT_INSTALL" jq >"$outfile" 2>&1
    set -e
    command rm -f "$outfile"
    command chmod 755 "$dir"

    local sudo_used=0
    [ -f "$marker" ] && sudo_used=1
    command rm -f "$marker"
    assert_equals "1" "$sudo_used" \
        "Elevation IS reached when the sources directory is not writable"
}

# The fail-loud branch of the rename itself. This repo's runtime policy is that
# a tool exits non-zero with an actionable message rather than continuing on a
# half-done job — and for the disable step, this is the branch that implements
# it. Left untested, a rename that silently stopped failing loud would leave CI
# running apt-get against sources it believed it had disabled.
#
# Forced with an elevation stand-in that always fails, against a directory the
# predicate will not let us write.
test_mv_failure_is_loud() {
    local dir failing_sudo out
    dir="$(new_sources_dir)"
    command printf 'deb https://a.invalid/ stable main\n' >"$dir/a.list"
    failing_sudo="$SANDBOX_ROOT/failing-sudo"
    # Heredoc rather than `printf '#!/bin/sh\n...'`: the portability gate reads
    # an interpreter path inside a printf format as a hardcoded core-utility
    # path (#443) and fails the file. Same shape as MARKER_SUDO below.
    command cat >"$failing_sudo" <<'FAILING'
#!/bin/sh
exit 1
FAILING
    command chmod +x "$failing_sudo"
    command chmod 555 "$dir"

    if [ -w "$dir" ]; then
        command chmod 755 "$dir"
        skip_test "running as root (uid $(command id -u)); -w ignores mode bits"
        return 0
    fi

    local outfile="$SANDBOX_ROOT/mvfail.$$"
    set +e
    APT_SOURCES_LIST_D="$dir" APT_INSTALL_SKIP_APT=1 \
        APT_INSTALL_SUDO="$failing_sudo" \
        bash "$APT_INSTALL" jq >"$outfile" 2>&1
    local status=$?
    set -e
    out="$(command cat "$outfile")"
    command rm -f "$outfile"
    command chmod 755 "$dir"

    assert_equals "1" "$status" "A failed rename exits non-zero"
    assert_contains "$out" "failed to disable apt source" \
        "The failure names what could not be disabled"
}

# The elevation override is honored ONLY under APT_INSTALL_SKIP_APT=1, so that a
# value leaking in from a CI matrix cannot substitute the privileged command in a
# production run.
#
# THE TRUE BRANCH is what the three tests above exercise. The FALSE branch —
# override set, skip mode off — cannot be driven end-to-end here: with the gate
# closed the script proceeds to a real `apt-get update`, which this suite must
# not run. So the assertion is structural: the guard must still be spelled with
# the SKIP_APT conjunct. That is weaker than a behavioural test and is stated as
# such rather than dressed up — it catches the regression that matters (the
# conjunct being dropped or weakened to `||`, which no other test would notice)
# and nothing subtler.
#
# assert_file_defines is deliberate: a plain grep would be satisfied by the
# explanatory comment directly above the guard, which names the same variable
# (#830). Here it anchors the SUDO assignment itself.
test_sudo_override_is_gated_on_skip_mode() {
    assert_file_defines "$APT_INSTALL" "SKIP_APT" \
        "SKIP_APT is assigned from the environment"
    # The pattern is a BRE, so `[` would open a character class — match on the
    # unambiguous middle of the conjunction instead of the bracketed tests.
    assert_file_contains "$APT_INSTALL" \
        '"$SKIP_APT" = "1" .* -n "${APT_INSTALL_SUDO:-}"' \
        "The elevation override is conjoined with skip mode, not honored alone"
}

test_script_is_executable_shell() {
    assert_file_exists "$APT_INSTALL" "bin/apt-install.sh exists"
    assert_true "bash -n '$APT_INSTALL'" "The script parses as valid bash"
}

SANDBOX_ROOT="$(command mktemp -d)" || {
    command printf 'FATAL: mktemp -d failed; cannot run apt-install tests\n' >&2
    exit 1
}

# A stand-in for sudo, passed to the script as APT_INSTALL_SUDO. It touches
# $MARKER_FILE so the caller can tell whether elevation was reached, re-opens
# $TARGET_DIR when one is given (what real sudo would achieve for a root-owned
# sources dir), then runs the command it was handed.
MARKER_SUDO="$SANDBOX_ROOT/marker-sudo"
command cat >"$MARKER_SUDO" <<'MARKER'
#!/bin/sh
[ -n "${MARKER_FILE:-}" ] && touch "$MARKER_FILE"
[ -n "${TARGET_DIR:-}" ] && chmod u+w "$TARGET_DIR"
exec "$@"
MARKER
command chmod +x "$MARKER_SUDO"

run_test test_script_is_executable_shell "Script exists and parses"
run_test test_disables_list_file "A .list third-party source is disabled"
run_test test_disables_sources_file "A deb822 .sources source is disabled"
run_test test_disables_every_source "Every bundled source is disabled, not one by name"
run_test test_keeps_ubuntu_own_sources "Ubuntu's own archive survives the sweep"
run_test test_empty_dir_is_not_an_error "An empty sources.list.d is tolerated"
run_test test_missing_dir_is_not_an_error "A missing sources.list.d is tolerated"
run_test test_rerun_is_idempotent "Re-running does not re-disable or double-rename"
run_test test_command_carries_retries "apt-get carries Acquire::Retries=3 and the packages"
run_test test_multiple_packages_preserved "Multiple package arguments are preserved"
run_test test_no_packages_is_an_error "No packages fails loud with a usage error"
run_test test_rename_does_not_invoke_sudo "A sandbox rename does not shell out to sudo"
run_test test_rename_invokes_sudo_when_dir_unwritable "An unwritable sources dir DOES use sudo"
run_test test_mv_failure_is_loud "A failed rename exits non-zero with a named source"
run_test test_sudo_override_is_gated_on_skip_mode "The elevation override is gated on skip mode"

generate_report
