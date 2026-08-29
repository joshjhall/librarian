#!/usr/bin/env bash
# check-decomposition detector behavioral gate (issue #663).
#
# check-decomposition is the single source of truth for production-LOC counting
# across the audit plugins: the per-language exclusion rules that
# audit-code-health, audit-architecture and audit-ai-config each carried as their
# own drifting prose copy now live in one scanner, and the deliverable is an
# actionable SEAM ("lines 412-680, the parse_* family, fan-in 1 -> parser/parse.rs")
# rather than a bare line count.
#
# This is the behavioral half of the #204 two-surface convention for that
# scanner. validate-python-ports.sh only asserts bash==python PARITY over a
# shared fixture tree, which — as its own header notes — "cannot catch a
# regression where both impls break the same way". This gate pins the actual
# detector output: for each of the six segmenters (Python, JS/TS, Rust, Go,
# Shell, Markdown) a purpose-built fixture must produce a seam with the RIGHT
# span, family and fan-in, and a counter-fixture must stay silent.
#
# It also carries the ai-file-bloat / doc-file-bloat cases MOVED here from
# tests/validate-checker-detectors.sh when #663 moved those categories off
# check-ai-config — including the #494 flat-vs-nested agent glob arms and the
# #222 "docs bloat does not emit under ai-file-bloat" counter. Moving them
# preserves the coverage across the ownership change instead of deleting it.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# MUTATION-VERIFIED (the #221 precedent, and the reason the issue demanded it).
# Every segmenter assertion below was proven to catch a regression by transiently
# breaking the scanner and confirming this gate goes red, then reverting. An
# unmutated fixture can pass with AND without the feature — see the
# anchored-regex-tautological-test and escaped-fixture-cannot-self-match lessons.
# The mutations checked, one per segmenter plus the shared machinery:
#   py       — UNIT_RE["py"] def/class arm made non-matching     -> 2 cases red
#   js       — UNIT_RE["js"] function arm made non-matching      -> 1 case  red
#   rs       — UNIT_RE["rs"] fn/impl arm made non-matching       -> 1 case  red
#   go       — UNIT_RE["go"] func arm made non-matching          -> 2 cases red
#   sh       — UNIT_RE["sh"] paren arm made non-matching         -> 1 case  red
#   md       — the heading regex in find_units made non-matching -> 1 case  red
#   fan_in   — early-returned (0, "")                            -> 4 cases red
#   test-excl— TEST_UNIT_RE["go"] made non-matching              -> 1 case  red
#   decline  — the decline emit branch disabled                  -> 1 case  red
#   god-mod  — the >= god_concerns requirement relaxed to >= 0   -> 1 case  red
#   adjacency— the index-adjacency guard dropped, in BOTH impls  -> 1 case  red
#              (py: `and idx == last_idx + 1`; sh: `clast[nc] == i - 1`)
#   prose-decline — comment_pct >= 50 raised to >= 99, BOTH impls -> 1 case red
#   decline-order — the cohesive branch disabled so prose wins    -> 1 case red
#   py-region — the `if __name__` marker, BOTH impls              -> 1 case red
#   sh-region — the `# --- tests ---` marker, BOTH impls          -> 1 case red
#   fanin-cap — the `count <= seam_max_fanin` guard dropped, BOTH -> 1 case red
#   fanin-callers — the `and callers` guard dropped, BOTH impls  -> 1 case red
#   rs-pending — the standalone-#[test] attribute carry, BOTH impls-> 1 case red
#   split-shape— every SPLIT_SHAPE value emptied, BOTH impls        -> 1 case red
#   shape-gate — `seams > 0` relaxed to `over || seams > 0`, BOTH   -> 1 case red
#   bundle-pre — the bundle early return/exit dropped, BOTH impls   -> 2 cases red
# All went red under mutation and green on revert.
#
# The bundle-precedence case (#725) is the one that had to be REBUILT after its
# mutation: the obvious fixture — an index of unrelated `## Golem`/`## Review`
# topics — produces no markdown seam at all, so it emitted no generic shape row
# with the suppression AND none without it. Green either way, proving nothing.
# Its headings are now a same-family cluster, which is what makes the negative
# assertion arm ([[gate-and-evidence-converge-tautology]]).
#
# The last six were added by the pre-PR review. Cycle 1: the fourth decline
# reason and the two whole-file test-REGION markers were exercised only by the
# Codecov corpus, which asserts nothing — so a broken region regex would have
# shown green coverage and a green suite simultaneously. Note `decline-order`:
# it pins the BRANCH ORDER, not just the predicate, since a reason chosen by the
# wrong arm is still a wrong finding. Cycle 3: the third fan-in evidence shape
# (a bare `fan-in N`, reached both over the cap and when no reference resolves
# to a top-level unit) had no assertion at all — its case carries a control that
# raises the cap so the same fixture DOES name its callers, so the bare-count
# assertion cannot pass merely because caller resolution broke.
#
# The adjacency case is here BECAUSE the first mutation round found it was the
# one rule with no failing test — the suite stayed green with the guard removed.
# That is the anchored-regex-tautological-test failure mode caught in the act:
# a rule nothing asserts is a rule that silently regresses. Its fixture carries a
# positive control (the same family, contiguous, MUST still be a seam) so the
# negative cannot pass merely because the segmenter stopped matching entirely.
#
# The scanner reads only file CONTENT (no git-rooting), so every fixture runs
# from $WORKDIR and CWD is irrelevant.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
# Pure bash-3.2 + coreutils; full command paths per project convention.
#
# THIS FILE IS A THIN ENTRY POINT (issue #760, the #564 convention). The cases
# live in per-language and per-category fragments under
# tests/validate-decomposition-detectors/, and the shared scratch dir plus the
# emit_rows / assert_fires / assert_silent / fresh_dir / list_of drivers live in
# tests/lib/decomposition-sandbox.sh. The explicit FRAGMENTS list below fixes the
# source order and is guarded, so an unwired fragment cannot silently contribute
# zero tests. Add a new language's cases to the fragment that owns the area (or a
# new fragment, added to BOTH the list below and the dispatch) — never here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# All read by tests/lib/decomposition-sandbox.sh and the area fragments, both
# sourced below — shellcheck analyses one file at a time and so cannot see those
# uses. The `{ ... }` group is what gives the directive block scope; a bare
# directive line only covers the statement that follows it.
# shellcheck disable=SC2034  # consumed by the sourced sandbox/fragments, not by this file
{
    SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/check-decomposition"
    PY="$SKILL_DIR/patterns.py"
    SH="$SKILL_DIR/patterns.sh"

    # Resolved once so the bash-fallback driver runs under a real interpreter
    # rather than whatever `bash` a fixture's stripped PATH would find.
    REAL_BASH="$(command -v bash)"
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-decomposition detector fixtures (#663)"

# --- Shared drivers + area fragments ----------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# Sourcing this creates $WORKDIR and installs its cleanup trap (side-effecting by
# design — see the file header) and defines the five scanner drivers.
# shellcheck source=tests/lib/decomposition-sandbox.sh
source "$SCRIPT_DIR/lib/decomposition-sandbox.sh"

source_fragments "$SCRIPT_DIR/validate-decomposition-detectors" \
    01-python.sh \
    02-js-ts.sh \
    03-swift.sh \
    04-rust.sh \
    05-go.sh \
    06-shell-md.sh \
    07-split-shape.sh \
    08-fanin-decline.sh \
    09-bloat.sh \
    10-memory-bundle.sh

# --- Dispatch ---------------------------------------------------------------
run_fragment_test test_seam_python "python: def-family seam, span/fan-in/target, test exclusion"
run_fragment_test test_seam_js "js: camelCase family seam + describe() test exclusion"
run_fragment_test test_seam_typescript "ts: type-level units, seam-not-decline, .d.ts decline, ts shape (#726)"
run_fragment_test test_separate_file_tests_are_production "js/ts/py: separate-file tests measure as production; describe() is a unit (#851)"
run_fragment_test test_same_file_regions_still_exclude "rs/py: same-file test regions at a non-test path still exclude (#851)"
run_fragment_test test_test_file_directory_arm_and_seam "ts: tests/ directory arm; a test file yields a SEAM, not just a size (#851)"
run_fragment_test test_test_file_relative_leading_segment "ts: a LEADING tests/ segment on a relative path; contest.ts counter (#851)"
run_fragment_test test_test_file_remaining_arms "ts: spec/__tests__/__pycache__ segments and *_spec/*.spec basenames (#851)"
run_fragment_test test_seam_swift "swift: unit forms, /// comment model, both test conventions, seam-not-decline (#728)"
run_fragment_test test_seam_rust "rust: fn-family seam + #[cfg(test)] region exclusion"
run_fragment_test test_seam_go "go: func-family seam + func Test exclusion"
run_fragment_test test_rust_impl_clustering "rust: impl Trait for Type clusters by type; impl is one unit (#727)"
run_fragment_test test_rust_item_coverage "rust: macro_rules/unsafe/const/extern/static/type all segment (#727)"
run_fragment_test test_rust_impl_matches_in_linear_time "rust: the impl arm matches in linear time (ReDoS guard, #727)"
run_fragment_test test_rust_midfile_test_region "rust: mid-file #[cfg(test)] is module-scoped; indented #[test] does not leak (#727)"
run_fragment_test test_go_method_receivers "go: methods cluster by receiver; grouped decls are visible (#727)"
run_fragment_test test_go_method_test_classification "go: a testify Test method stays test-classified (#727)"
run_fragment_test test_seam_shell "shell: function-family seam + comment exclusion"
run_fragment_test test_seam_markdown "markdown: heading-cluster seam + fenced-block counter"
run_fragment_test test_split_shape_per_language "shape: every language arm is reachable and language-specific (#725)"
run_fragment_test test_split_shape_not_emitted_beside_a_decline "shape: a declined file gets a reason, not a destination (#725)"
run_fragment_test test_split_shape_suppressed_for_memory_bundles "shape: bundle guidance pre-empts generic md advice (#725/#700)"
run_fragment_test test_fanin_over_cap "fan-in: bare-count shape (over cap, and module-level references)"
run_fragment_test test_adjacency_required "adjacency: interleaved family rejected, contiguous family accepted"
run_fragment_test test_decline_reasons "decline: generated / cohesive / mutually-referential, each with a reason"
run_fragment_test test_ai_file_bloat "ai-file-bloat: warn/high arms, flat+nested agent globs (moved from #204 gate)"
run_fragment_test test_companion_md_bloat "companion_md: skills/*/other.md arms + SKILL.md ordering (#589)"
run_fragment_test test_doc_file_bloat "doc-file-bloat: docs/*.md arms, not ai-file-bloat (moved from #204 gate)"
run_fragment_test test_size_verdict_exclusivity "exclusivity: one size verdict per file — type budget XOR file-length (#701)"
run_fragment_test test_god_module "god-module: concern spread required, size alone insufficient"
run_fragment_test test_skips_and_thresholds "skips: lock files; thresholds: project-overridable"
run_fragment_test test_memory_bundle_bloat "memory: bundle index/concept budgets, configurable root, never code-sized (#700)"
run_fragment_test test_memory_split_guidance "memory: topic-cluster index split, anti-orphan concept split (#700)"
run_fragment_test test_memory_gitignored_reachability "memory: a gitignored bundle file is still classified (#578/#700)"

generate_report
