#!/usr/bin/env bash
# Empty / missing-input robustness suite for the deterministic pre-scan scripts
# (patterns.sh + pre-review-gates.sh) bundled with the plugins.
#
# These scripts are invoked with a file list derived from `git diff`; in a PR
# that touches no relevant file types that list is empty. They are also a common
# edit target. This stage pins their edge-case contract so a regression is
# caught before it produces false-positive gate failures:
#
#   1. Empty file list  → exit 0, and (with documented exemptions) no output.
#   2. No argument      → exit 1 (usage error) with a `Usage` message on stderr.
#
# Discovery is dynamic (find), so a newly added pre-scan is covered automatically
# without editing this file. Pure bash + coreutils; no Docker. Uses the shared
# harness assertion helpers (assert_exit, assert_output_empty).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Pre-scan empty/missing-input robustness"

# Two empty file-list files; the scratch dir is cleaned up on exit. A pre-scan
# that reads its input line-by-line sees zero lines from these.
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT
EMPTY1="$WORKDIR/empty1.txt"
EMPTY2="$WORKDIR/empty2.txt"
: >"$EMPTY1"
: >"$EMPTY2"

# List every pre-scan script across all plugins (absolute paths, sorted).
list_prescans() {
    command find "$PLUGINS_DIR" -type f \
        \( -name 'patterns.sh' -o -name 'pre-review-gates.sh' \) \
        2>/dev/null | command sort
}

# Per-script invocation arity. drift-detect/patterns.sh takes TWO file-list args
# by design (actual + planned changed files); every other pre-scan takes one.
# A script needing two args but given one would exit 1 on a legitimately empty
# diff, so the empty-list invocation must pass the right arity.
prescan_is_two_arg() {
    case "$1" in
        */drift-detect/patterns.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# Scripts EXEMPT from the empty-list "output must be empty" assertion because of
# a known spurious-finding bug (NOT by-design): they still exit 0, but they emit
# findings on empty input. Each carries the tracking issue so the exemption can
# be removed once the source is fixed.
#
#   check-docs-organization/patterns.sh — scans the project root for standard
#   docs regardless of the passed file list, so an empty list still yields
#   `missing-root-doc` findings. Tracked in issue #64.
prescan_output_exempt() {
    case "$1" in
        */check-docs-organization/patterns.sh) return 0 ;; # see issue #64
        *) return 1 ;;
    esac
}

# --- Empty file list: exit 0 (+ empty output unless exempt) -----------------

test_prescans_empty_list() {
    local script
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        local rel rc=0 out
        rel="${script#"$PLUGINS_DIR"/}"

        if prescan_is_two_arg "$script"; then
            out="$(bash "$script" "$EMPTY1" "$EMPTY2" 2>/dev/null)" || rc=$?
        else
            out="$(bash "$script" "$EMPTY1" 2>/dev/null)" || rc=$?
        fi

        assert_exit 0 "$rc" "Pre-scan $rel: empty file list should exit 0"
        if prescan_output_exempt "$script"; then
            # Known-bug carve-out (issue #64): output is NOT
            # asserted empty. This is an exemption, not a blessing — the script
            # SHOULD emit nothing on empty input; the tracking issue holds the
            # real fix, after which this exemption must be removed.
            :
        else
            assert_output_empty "$out" \
                "Pre-scan $rel: empty file list should emit no findings"
        fi
    done < <(list_prescans)
}

# --- No argument: exit 1 with a usage error ---------------------------------

test_prescans_missing_arg() {
    local script
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        local rel rc=0 err
        rel="${script#"$PLUGINS_DIR"/}"

        # Close stdin so a script that ignores the arg error and falls through
        # to a read loop cannot block waiting on the terminal.
        err="$(bash "$script" </dev/null 2>&1 >/dev/null)" || rc=$?

        assert_exit 1 "$rc" "Pre-scan $rel: missing argument should exit 1"
        assert_contains "$err" "Usage" \
            "Pre-scan $rel: missing argument should print a usage error"
    done < <(list_prescans)
}

# --- Run All Tests ----------------------------------------------------------

run_test test_prescans_empty_list "Every pre-scan exits 0 (no spurious output) on an empty file list"
run_test test_prescans_missing_arg "Every pre-scan exits 1 with a usage error on no argument"

generate_report
