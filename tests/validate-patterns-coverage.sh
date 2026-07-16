#!/usr/bin/env bash
# Behavioral gate for bin/check-patterns-coverage.sh (issue #240).
#
# The tool reports per-domain deterministic coverage for the check-* scanner
# skills (contract.md Categories table vs the slugs patterns.sh/patterns.py
# actually emit) and, with --strict, gates on an overall threshold. This suite
# pins:
#
#   1. Report mode over the REAL skills tree — every check-* domain is listed,
#      an Overall line is printed, and the tool exits 0.
#   2. --strict self-test over COMMITTED FIXTURES — a full-coverage tree passes
#      `--strict 100` and a gapped tree fails it but passes `--strict 0`. This
#      proves both arms of the gate actually fire, independent of the real
#      tree's exact figure (which drifts as scanners gain categories).
#   3. Fail-loud — pointed at a directory with no check-* domains, the tool
#      exits non-zero rather than reporting a misleading 0/0.
#   4. Robustness — a domain whose contract.md has a `## Categories` header but
#      no extractable slugs is SKIPPED, not fatal: the tool still reports a
#      well-formed sibling and exits 0 (regression guard for the set -e/pipefail
#      abort the pre-PR review caught).
#   5. Bare --strict uses the default threshold (80).
#   6. Arg-parsing arms (#341) — --skills-dir with no value exits 1, -h/--help
#      exits 0 with usage; complements the --bogus-flag case in (unknown-arg).
#   7. Dual-impl union (#341) — emitted_categories() unions slugs across BOTH
#      patterns.sh and patterns.py (check-demo-dual: a py-only category counts).
#   8. Categories sed scoping (#341) — a category-shaped token outside the
#      `## Categories` block (check-demo-scope) is NOT counted.
#   9. Edge-slug extractor parity (#341) — contract_categories() and
#      emitted_categories() share the strict kebab shape, so an edge slug like
#      x-finding (single-char first segment) is treated identically by both
#      (check-demo-edge stays 1/1; a loosened contract regex would drop it to
#      1/2 and fail --strict 100).
#
# Pure bash + coreutils; no node/jq. See CLAUDE.md § Runtime policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

TOOL="$REPO_ROOT/bin/check-patterns-coverage.sh"
FIXROOT="$SCRIPT_DIR/fixtures/patterns-coverage"

test_suite "check-* deterministic coverage tool (#240)"

# --- The tool exists and is the script under test ---------------------------

test_tool_present() {
    assert_file_exists "$TOOL" "bin/check-patterns-coverage.sh must exist"
}
run_test test_tool_present "tool script is present"

# --- Report mode over the real skills tree ----------------------------------

REAL_OUT=""
REAL_RC=0
if REAL_OUT="$(bash "$TOOL" 2>&1)"; then REAL_RC=0; else REAL_RC=$?; fi

test_report_exit_zero() {
    assert_equals "0" "$REAL_RC" "report mode (no --strict) exits 0 on the real tree"
}
run_test test_report_exit_zero "report mode exits 0"

test_report_lists_all_domains() {
    # Every check-* skill that ships a contract.md must appear in the report.
    local d name
    for d in "$REPO_ROOT"/plugins/review-audit/skills/check-*; do
        [ -f "$d/contract.md" ] || continue
        name="$(command basename "$d")"
        assert_contains "$REAL_OUT" "$name" "report lists domain $name"
    done
}
run_test test_report_lists_all_domains "report lists every check-* domain"

test_report_has_overall_line() {
    assert_contains "$REAL_OUT" "Overall:" "report prints an Overall summary line"
    assert_contains "$REAL_OUT" "deterministic coverage" "Overall line names the metric"
}
run_test test_report_has_overall_line "report prints an Overall line"

# --- --strict self-test over committed fixtures -----------------------------

test_full_fixture_passes_strict_100() {
    local rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/full" --strict 100 >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "full-coverage fixture passes --strict 100"
}
run_test test_full_fixture_passes_strict_100 "full fixture passes --strict 100"

test_gapped_fixture_fails_strict_100() {
    local rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/gapped" --strict 100 >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "gapped fixture fails --strict 100"
}
run_test test_gapped_fixture_fails_strict_100 "gapped fixture fails --strict 100"

test_gapped_fixture_passes_strict_0() {
    local rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/gapped" --strict 0 >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "gapped fixture passes --strict 0 (report threshold met)"
}
run_test test_gapped_fixture_passes_strict_0 "gapped fixture passes --strict 0"

# Bare `--strict` (no explicit threshold) must apply the default of 80: the
# 100%-covered full fixture passes, the 33%-covered gapped fixture fails.
test_bare_strict_uses_default_threshold() {
    local rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/full" --strict >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "full fixture passes bare --strict (100% >= default 80)"
    rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/gapped" --strict >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "gapped fixture fails bare --strict (33% < default 80)"
}
run_test test_bare_strict_uses_default_threshold "bare --strict uses the default threshold (80)"

test_gapped_fixture_reports_missing() {
    local out
    out="$(bash "$TOOL" --skills-dir "$FIXROOT/gapped" 2>&1)"
    assert_contains "$out" "1/3" "gapped fixture reports 1/3 covered"
    assert_contains "$out" "missing:" "gapped fixture names the missing categories"
    assert_contains "$out" "gamma-finding" "gapped fixture lists the missing gamma-finding"
}
run_test test_gapped_fixture_reports_missing "gapped fixture reports missing categories"

# --- Fail-loud on an empty scan ---------------------------------------------

test_empty_dir_fails_loud() {
    local tmp rc=0 out
    tmp="$(command mktemp -d)"
    out="$(bash "$TOOL" --skills-dir "$tmp" 2>&1)" || rc=$?
    command rmdir "$tmp"
    assert_equals "1" "$rc" "empty skills dir exits non-zero (fail loud, not 0/0)"
    assert_contains "$out" "no check-* domains" "empty scan prints an actionable message"
}
run_test test_empty_dir_fails_loud "empty scan fails loud"

# --- Robustness: a malformed contract skips, does not abort ------------------
# Regression guard for the set -e/pipefail abort: check-demo-zzz has a
# `## Categories` header with no extractable slugs. The tool must skip it and
# still report the well-formed check-demo-ok sibling, exiting 0.

test_malformed_contract_is_skipped_not_fatal() {
    local out rc=0
    out="$(bash "$TOOL" --skills-dir "$FIXROOT/malformed" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "malformed sibling does not abort the scan (exit 0)"
    assert_contains "$out" "check-demo-ok" "well-formed sibling is still reported"
    assert_not_contains "$out" "check-demo-zzz" "empty-Categories domain is skipped, not listed"
}
run_test test_malformed_contract_is_skipped_not_fatal "malformed contract is skipped, not fatal"

# --- Unknown-argument rejection ---------------------------------------------

test_unknown_arg_rejected() {
    local rc=0
    bash "$TOOL" --bogus-flag >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "unknown argument is rejected with non-zero exit"
}
run_test test_unknown_arg_rejected "unknown argument is rejected"

# --- Remaining arg-parsing paths (#341) -------------------------------------
# --bogus-flag (above) covers the unknown-argument arm; these pin the two
# untested arms: --skills-dir with no value (usage + exit 1), and -h/--help
# (usage + exit 0).

test_skills_dir_missing_value_rejected() {
    local rc=0
    bash "$TOOL" --skills-dir >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "--skills-dir with no value exits non-zero"
}
run_test test_skills_dir_missing_value_rejected "--skills-dir without a value is rejected"

test_help_flag_exits_zero() {
    local rc=0 out
    out="$(bash "$TOOL" --help 2>&1)" || rc=$?
    assert_equals "0" "$rc" "--help exits 0"
    assert_contains "$out" "Usage:" "--help prints the usage line"
    rc=0
    bash "$TOOL" -h >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "-h exits 0"
}
run_test test_help_flag_exits_zero "-h/--help prints usage and exits 0"

# --- Dual patterns.sh + patterns.py union (#341) ----------------------------
# check-demo-dual declares two categories: sh-finding (emitted only by
# patterns.sh) and py-finding (emitted only by patterns.py). The tool must union
# slugs across BOTH files to score it 2/2 — proving emitted_categories() reads
# patterns.py, not just patterns.sh. Read-only patterns.sh would leave the
# domain at 1/2 and fail --strict 100.

test_dual_impl_union_counts_both() {
    local out rc=0
    out="$(bash "$TOOL" --skills-dir "$FIXROOT/full" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "full tree (incl. dual fixture) reports and exits 0"
    assert_contains "$out" "check-demo-dual" "dual fixture appears in the report"
    assert_contains "$out" "check-demo-dual            2/2" "dual fixture scores 2/2 (sh+py unioned)"
    rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/full" --strict 100 >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "dual-impl union keeps the full tree at --strict 100"
}
run_test test_dual_impl_union_counts_both "dual patterns.sh+patterns.py union counts both"

# --- Categories-table sed scoping (#341) ------------------------------------
# check-demo-scope declares real-finding inside `## Categories` and a
# category-shaped token zzz-should-not-count in the LATER `## Finding Format`
# section. The `sed -n '/^## Categories/,/^## /p'` range must exclude the
# out-of-section token: the domain is 1/1 (100%), and zzz-should-not-count never
# surfaces in the report.

test_categories_sed_scoping_excludes_outside_token() {
    local out rc=0
    out="$(bash "$TOOL" --skills-dir "$FIXROOT/scoping" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "scoping fixture reports and exits 0"
    assert_contains "$out" "check-demo-scope           1/1" "scope fixture is 1/1 (out-of-section token not counted)"
    assert_not_contains "$out" "zzz-should-not-count" "out-of-section token never appears in the report"
    rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/scoping" --strict 100 >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "scoping fixture stays 100% (token excluded, total is 1 not 2)"
}
run_test test_categories_sed_scoping_excludes_outside_token "Categories sed scoping excludes out-of-section tokens"

# --- Edge-slug extractor parity (#341) --------------------------------------
# check-demo-edge declares real-finding and the edge slug x-finding (single-char
# first segment), both emitted by patterns.sh. The strict kebab shape excludes
# x-finding from BOTH extractors symmetrically, so the domain is 1/1. This pins
# contract_categories() and emitted_categories() to the same slug shape: if the
# contract extractor is loosened back to [a-z][a-z0-9-]+, x-finding becomes
# declared-but-never-emitted (1/2) and --strict 100 fails.

test_edge_slug_extractor_parity() {
    local out rc=0
    out="$(bash "$TOOL" --skills-dir "$FIXROOT/edge" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "edge fixture reports and exits 0"
    assert_contains "$out" "check-demo-edge            1/1" "edge fixture is 1/1 (x-finding ignored by both extractors)"
    assert_not_contains "$out" "missing: x-finding" "x-finding is not reported missing (extractors agree)"
    rc=0
    bash "$TOOL" --skills-dir "$FIXROOT/edge" --strict 100 >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "edge fixture stays 100% under extractor parity"
}
run_test test_edge_slug_extractor_parity "edge-slug extractor parity (contract vs emitted regex)"

generate_report
