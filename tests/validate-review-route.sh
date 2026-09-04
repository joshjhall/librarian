#!/usr/bin/env bash
# review-route.sh — routing decision + fail-safe properties (issue #550).
#
# The script decides whether a review cycle runs the full 7-agent fan-out or the
# cheap doc/config-only path. Because a `cheap` cycle is allowed to return
# `clean: true` — and `clean` is half the merge invariant — THE CLASSIFIER IS
# THE ENTIRE SAFETY ARGUMENT. If it can be made permissive without a test going
# red, the invariant is protected by nothing but a comment.
#
# So this suite is organized around the direction of failure, not around
# coverage. Two kinds of case:
#
#   1. RULE CASES — each rule fires on an input that reaches it, pinning the
#      documented verdict, rule name and dimension list.
#
#   2. FAIL-SAFE CASES — the ones the suite exists for. Each is built on an
#      input where a PERMISSIVE classifier would answer `cheap` and the correct
#      one answers `full`. That is the discipline this repo's memory calls
#      "fixture must express the divergent case": asserting `full` on an input
#      both versions route `full` is a tautology that passes with AND without
#      the fix.
#
# The mutation obligation is stated per-case below: neutering R2-source,
# R3-unknown or the R1 env override must each turn a NAMED test red.
#
# Pure bash + coreutils via `command`; no node, no jq, no network. bash-3.2
# clean, BSD-regex clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RR="$REPO_ROOT/plugins/workflow/scripts/review-route.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-route.sh routing decision (#550)"

# val <key> <output> — echo the value of a `key=value` line. Keeps assertions
# terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# mklist <line>... — write a newline-separated file list to a temp file and echo
# its path.
mklist() {
    _f="$(command mktemp)"
    for _l in "$@"; do
        command printf '%s\n' "$_l"
    done >"$_f"
    command printf '%s\n' "$_f"
}

# route_of <file-list> [extra args...] — run the script and echo just the route.
route_of() {
    _list="$1"
    shift
    bash "$RR" check --files "$_list" "$@"
}

# --- 1. Rule cases -----------------------------------------------------------

# The one path to `cheap`. Also pins the dimension contract: scope-drift ALONE.
test_doc_and_config_only_routes_cheap() {
    local list out
    list="$(mklist 'README.md' 'docs/guide.md' 'config.yaml' 'data.json')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" "doc/config-only diff routes cheap"
    assert_equals "R5-doc-config" "$(val rule "$out")" "R5 is the deciding rule"
    assert_equals "scope-drift" "$(val dimensions "$out")" \
        "cheap path runs scope-drift ALONE"
    assert_equals "2" "$(val doc_files "$out")" "counts both doc files"
    assert_equals "2" "$(val config_files "$out")" "counts both config files"
}

# scope-drift surviving the cheap path is a REQUIREMENT, not an accident: it is
# the only dimension reading the issue's ACs, and a doc-only diff can fail one.
# Asserted by name so deleting it from the cheap branch fails here.
test_scope_drift_survives_the_cheap_route() {
    local list out
    list="$(mklist 'CHANGELOG.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" "single doc file routes cheap"
    assert_contains "$(val dimensions "$out")" "scope-drift" \
        "scope-drift is retained on the cheap path (AC-completeness lens)"
}

test_full_route_names_every_dimension() {
    local list out dims
    list="$(mklist 'src/app.py')"
    out="$(route_of "$list")"
    dims="$(val dimensions "$out")"

    for d in security correctness tests conventions decomposition scope-drift; do
        assert_contains "$dims" "$d" "full route runs the $d dimension"
    done
}

# --- 2. Fail-safe cases ------------------------------------------------------
#
# Every case below is built so a PERMISSIVE classifier answers `cheap`.

# MUTATION TARGET: R2-source. Neuter it and this test must go red.
# The fixture is 20 docs plus ONE source file — a classifier that ignored the
# source file (e.g. checked "mostly docs", or a majority, or only the first
# entry) would route `cheap`. That is the divergent case.
test_one_source_file_among_many_docs_forces_full() {
    local list out
    list="$(mklist \
        'a.md' 'b.md' 'c.md' 'd.md' 'e.md' 'f.md' 'g.md' 'h.md' 'i.md' 'j.md' \
        'k.md' 'l.md' 'm.md' 'n.md' 'o.md' 'p.md' 'q.md' 'r.md' 's.md' 't.md' \
        'src/auth.py')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a SINGLE source file among 20 docs forces the full fan-out"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source is the deciding rule"
    assert_equals "1" "$(val source_files "$out")" "the lone source file is counted"
}

# The same property at the other boundary: the source file LAST in the list, so
# a classifier that stopped at the first non-source answer also diverges.
test_source_file_last_in_list_forces_full() {
    local list out
    list="$(mklist 'README.md' 'notes.md' 'setup.cfg' 'deploy.sh')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a source file in the FINAL position still forces full"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source fires regardless of position"
}

# MUTATION TARGET: R3-unknown. Neuter it (or fold `unknown` into `doc`) and this
# must go red. A `.rb` file is not in the source table — a classifier treating
# "not known to be source" as "safe to skip" routes `cheap` here.
test_unknown_extension_forces_full() {
    local list out
    list="$(mklist 'README.md' 'lib/widget.rb')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "an UNRECOGNIZED extension forces full — unknown means possibly-source"
    assert_equals "R3-unknown" "$(val rule "$out")" "R3-unknown is the deciding rule"
    assert_equals "1" "$(val unknown_files "$out")" "the unknown file is counted"
}

# Extensionless build/infra files are executable logic the security and
# correctness dimensions genuinely review. Classified `unknown`, never `config`.
test_extensionless_infra_files_force_full() {
    local list out name
    for name in Dockerfile Makefile justfile; do
        list="$(mklist 'README.md' "$name")"
        out="$(route_of "$list")"
        assert_equals "full" "$(val route "$out")" \
            "$name forces full (build logic, not inert config)"
    done
}

# A path whose DIRECTORY looks documentary but whose file is source. Pins the
# basename anchoring: a classifier matching on the whole path could route cheap.
test_source_file_under_docs_directory_forces_full() {
    local list out
    list="$(mklist 'docs/examples/build.sh')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a .sh under docs/ is classified by BASENAME, not by directory"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source fires on the basename"
}

# The inverse anchoring trap: a directory named like a source file.
test_doc_under_source_looking_directory_still_routes_cheap() {
    local list out
    list="$(mklist 'app.py/NOTES.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "a .md inside a directory named app.py is still a doc"
}

# An empty or missing list is ambiguity, not emptiness-as-permission.
test_empty_list_forces_full() {
    local list out
    list="$(mklist)"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" "an EMPTY file list forces full"
    assert_equals "R0-empty" "$(val rule "$out")" "R0-empty is the deciding rule"
}

test_missing_list_file_forces_full() {
    local out
    out="$(bash "$RR" check --files "$REPO_ROOT/no-such-file-xyz.txt")"

    assert_equals "full" "$(val route "$out")" \
        "a MISSING file list forces full rather than reading as zero source files"
    assert_equals "R0-empty" "$(val rule "$out")" "R0-empty covers the missing-file case"
}

# MUTATION TARGET: the R1 env override. Neuter it and this goes red. The fixture
# is doc-only — i.e. a diff the classifier WOULD route cheap — so the test can
# only pass when the override is honored.
test_operator_override_forces_full() {
    local list out
    list="$(mklist 'README.md' 'docs/a.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=full bash "$RR" check --files "$list")"

    assert_equals "full" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE=full disables routing on a would-be-cheap diff"
    assert_equals "R1-forced" "$(val rule "$out")" "R1-forced is the deciding rule"
}

# A typo in the override must disable the optimization, not silently enable it.
test_malformed_override_value_forces_full() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=cheep bash "$RR" check --files "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a TYPO'd override value fails safe to full, never to cheap"
}

# `auto` is the documented default and must still permit routing — without this
# the override test above would also pass if the script ignored the var entirely
# and always returned full.
test_auto_override_permits_cheap() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=auto bash "$RR" check --files "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE=auto still allows the cheap path"
}

# --- 3. The line ceiling (R4) ------------------------------------------------
# It may only ever force `full`. The paired under/over cases prove it is read at
# all, and that it cannot manufacture a `cheap`.

test_diff_over_line_ceiling_forces_full() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list" --diff-lines 5000)"

    assert_equals "full" "$(val route "$out")" \
        "a doc-only diff OVER the line ceiling still forces full"
    assert_equals "R4-max-lines" "$(val rule "$out")" "R4-max-lines is the deciding rule"
}

test_diff_under_line_ceiling_routes_cheap() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list" --diff-lines 100)"

    assert_equals "cheap" "$(val route "$out")" \
        "a doc-only diff under the ceiling routes cheap"
}

test_line_ceiling_is_env_overridable() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE_MAX_LINES=50 bash "$RR" check --files "$list" --diff-lines 100)"

    assert_equals "full" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE_MAX_LINES lowers the ceiling"
}

# The ceiling cannot rescue a source diff into the cheap path — R2 outranks R4.
test_line_ceiling_cannot_make_a_source_diff_cheap() {
    local list out
    list="$(mklist 'src/tiny.py')"
    out="$(route_of "$list" --diff-lines 1)"

    assert_equals "full" "$(val route "$out")" \
        "a ONE-LINE source diff is still full — line count never yields cheap"
    assert_equals "R2-source" "$(val rule "$out")" "R2 outranks the line ceiling"
}

# --- 4. Fail-loud input validation -------------------------------------------

test_bad_diff_lines_fails_loud() {
    local out status
    local list
    list="$(mklist 'README.md')"
    set +e
    out="$(bash "$RR" check --files "$list" --diff-lines abc 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "a non-numeric --diff-lines exits 2"
    assert_contains "$out" "non-negative integer" "the error names the expected shape"
}

test_bad_env_ceiling_fails_loud() {
    local out status list
    list="$(mklist 'README.md')"
    set +e
    out="$(LIBRARIAN_REVIEW_ROUTE_MAX_LINES=xx bash "$RR" check --files "$list" 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "a non-numeric ceiling exits 2"
    assert_contains "$out" "LIBRARIAN_REVIEW_ROUTE_MAX_LINES" "the error names the variable"
}

test_missing_files_flag_fails_loud() {
    local out status
    set +e
    out="$(bash "$RR" check 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "omitting --files exits 2"
    assert_contains "$out" "--files is required" "the error says what is missing"
}

test_unknown_flag_and_subcommand_fail_loud() {
    local out status list
    list="$(mklist 'README.md')"
    set +e
    out="$(bash "$RR" check --files "$list" --bogus x 2>&1)"
    status=$?
    set -e
    assert_equals "2" "$status" "an unknown flag exits 2"
    assert_contains "$out" "unknown flag" "the error names the problem"

    set +e
    out="$(bash "$RR" frobnicate 2>&1)"
    status=$?
    set -e
    assert_equals "2" "$status" "an unknown subcommand exits 2"
    assert_contains "$out" "unknown subcommand" "the error names the problem"
}

# --- 5. Anti-vacuity ---------------------------------------------------------
# Every fail-safe test above asserts `full`. If the script were broken such that
# it returned `full` unconditionally, ALL of them would still pass. This is the
# guard against that whole class: at least one input must reach `cheap`.
test_cheap_is_reachable_at_all() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "ANTI-VACUITY: a plain doc-only diff reaches cheap — without this, a script \
that always returned 'full' would satisfy every fail-safe assertion in this file"
}

run_test test_doc_and_config_only_routes_cheap
run_test test_scope_drift_survives_the_cheap_route
run_test test_full_route_names_every_dimension
run_test test_one_source_file_among_many_docs_forces_full
run_test test_source_file_last_in_list_forces_full
run_test test_unknown_extension_forces_full
run_test test_extensionless_infra_files_force_full
run_test test_source_file_under_docs_directory_forces_full
run_test test_doc_under_source_looking_directory_still_routes_cheap
run_test test_empty_list_forces_full
run_test test_missing_list_file_forces_full
run_test test_operator_override_forces_full
run_test test_malformed_override_value_forces_full
run_test test_auto_override_permits_cheap
run_test test_diff_over_line_ceiling_forces_full
run_test test_diff_under_line_ceiling_routes_cheap
run_test test_line_ceiling_is_env_overridable
run_test test_line_ceiling_cannot_make_a_source_diff_cheap
run_test test_bad_diff_lines_fails_loud
run_test test_bad_env_ceiling_fails_loud
run_test test_missing_files_flag_fails_loud
run_test test_unknown_flag_and_subcommand_fail_loud
run_test test_cheap_is_reachable_at_all

generate_report
