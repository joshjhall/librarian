#!/usr/bin/env bash
# bounded-run.sh drift gate (#543).
#
# `bounded_run` exists in TWO places and must behave identically in both:
#
#   bin/bounded-run.sh                      — repo-level (tests/, justfile)
#   plugins/workflow/scripts/bounded-run.sh — plugin-level (golem-launch.sh)
#
# The duplication is deliberate, not laziness: the workflow plugin installs
# standalone via `claude plugin install`, so a user has plugins/workflow/ with no
# repo bin/ to source. The plugin cannot reach the repo copy, and a symlink does
# not survive the marketplace copy either.
#
# What duplication costs is drift — a portability fix landing in one copy and not
# the other reintroduces exactly the silent-degradation bug #543 fixed, in
# whichever copy was missed. This gate makes that impossible to do quietly. It
# follows the precedent of lint-skills-agents.sh's BUDGET_FLOOR consistency
# check: when a constant must agree across copies, pin it with a gate rather than
# trusting review to notice.
#
# Compares the CODE (function bodies), not the headers — the two files
# deliberately carry different provenance comments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "bounded-run.sh copies are in sync"

REPO_COPY="$REPO_ROOT/bin/bounded-run.sh"
PLUGIN_COPY="$REPO_ROOT/plugins/workflow/scripts/bounded-run.sh"

# The code region: from the first function definition to EOF. Everything above it
# is prose that is SUPPOSED to differ between the two copies.
extract_code() {
    command sed -n '/^bounded_run()/,$p' "$1"
}

test_both_copies_exist() {
    assert_file_exists "$REPO_COPY" "the repo-level copy exists"
    assert_file_exists "$PLUGIN_COPY" "the plugin-level copy exists"
}

test_code_regions_are_identical() {
    local repo_code plugin_code
    repo_code="$(extract_code "$REPO_COPY")"
    plugin_code="$(extract_code "$PLUGIN_COPY")"

    # NON-VACUITY FLOOR. If a rename moves the `bounded_run()` anchor, the sed
    # extracts NOTHING from both files — and "" equals "" would report PASS while
    # asserting nothing at all. Pin that the extraction actually found the code
    # before comparing it. Same trap class as
    # validate-lint-gates.sh's outcome-extraction floor.
    assert_true "[ \"$(command printf '%s' "$repo_code" | command wc -l)\" -gt 20 ]" \
        "the repo copy's code region was actually extracted (a broken anchor asserts nothing)"
    assert_contains "$repo_code" "bounded_run_available()" \
        "the extracted region reaches the last function"

    assert_equals "$repo_code" "$plugin_code" \
        "bin/ and plugins/workflow/scripts/ copies of bounded_run are byte-identical"
}

# The whole point of the function: it must not depend on GNU coreutils. A future
# edit that "simplifies" it back to `timeout` would silently restore #543 in
# whichever copy it touched, and the sync gate above would happily confirm both
# copies were equally broken.
test_neither_copy_depends_on_gnu_timeout() {
    local f
    for f in "$REPO_COPY" "$PLUGIN_COPY"; do
        assert_true "! command grep -qE '^[^#]*\\b(timeout|gtimeout) ' '$f'" \
            "${f##*/} bounds without GNU timeout/gtimeout (that dependency is the bug)"
    done
}

run_test test_both_copies_exist "both bounded-run.sh copies exist"
run_test test_code_regions_are_identical "the two copies' code regions are identical"
run_test test_neither_copy_depends_on_gnu_timeout "neither copy depends on GNU timeout"

generate_report
