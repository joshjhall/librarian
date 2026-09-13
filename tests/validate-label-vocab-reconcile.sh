#!/usr/bin/env bash
# Behavior gate for bin/label-vocab-reconcile.sh — the scheduled status/* label
# vocabulary reconciler (issue #938).
#
# WHAT THIS PINS, AND WHY IT IS NOT THE RECONCILIATION ITSELF. The reconciler
# needs network + `gh` auth, which is precisely why #921 deferred it to a
# SCHEDULED job (.github/workflows/label-vocab-reconcile.yml) instead of a
# run-all.sh stage: a gate needing auth would spend its life on the 77 skip
# sentinel, rendered `[SKIP] … did not run`, catching nothing. So this suite is
# the META-gate — it exercises the script's COMPARISON LOGIC against fixtures,
# with a stubbed `gh` on PATH. The same gate-vs-meta-gate split the repo already
# runs between lint-prose-budget.sh / validate-prose-budget.sh and
# ai-config-prescan.sh / validate-ai-config-prescan.sh.
#
# THE CENTRAL PROPERTY is that drift in EITHER direction fails the run. A suite
# that only asserted the live repo is currently clean would pass just as happily
# with both comparisons deleted — the reconciler would be inert and nobody would
# know until a deleted label took the pipeline down. Every case below is built on
# the arm that DISAGREES when the logic it targets is removed:
#
#   both directions clean          -> 0    (the control)
#   declared label absent live     -> 1    (the #938 direction; nothing else sees it)
#   live label undeclared          -> 1    (the other direction)
#   BOTH at once                   -> 1, and BOTH named (not collapsed to one row)
#   a live severity/* label        -> 0    (the status/ filter; else red forever)
#   gh absent from PATH            -> 2    (never 0)
#   gh present but failing         -> 2    (never 0 — an auth error is not an empty repo)
#   gh succeeds with no labels     -> 2    (never 0)
#   no declared vocabulary         -> 2    (never 0 — that is a parser regression)
#
# The four exit-2 cases matter more than they look. Each of them produces an
# EMPTY comparison, and an empty comparison is indistinguishable from "no drift"
# — the inert-gate shape this repo keeps filing issues about (#538, #571, #906).
# A reconciler that exited 0 when `gh` was unauthenticated would report a clean
# vocabulary every single week without ever querying anything.
#
# FIXTURES, NOT THE LIVE TREE, AND A STUBBED gh. Each case builds a throwaway
# plugins/ corpus under `mktemp -d`, points the script at it with
# LABEL_VOCAB_ROOT, and puts a `gh` shim first on PATH whose label list is
# whatever the case needs. Nothing here touches the real repo or the network, so
# this suite is legitimately offline and can be a run-all.sh stage while the scan
# itself stays scheduled-only.
#
# ONE PARSER, TWO CALLERS is asserted too: the reconciler and
# tests/lint-status-label-refs.sh must derive the same declared vocabulary from
# the same tree. That is the #663 property the extraction bought, and byte
# identity of two awk blocks was explicitly not the contract (#836).
#
# Pure bash + coreutils. bash-3.2 clean per CLAUDE.md § Runtime policy.
set -uo pipefail

#
# THIS FILE IS A THIN ENTRY POINT (issue #564, split while landing #999). The
# cases live in per-area fragments under tests/label-vocab-reconcile/, and the
# shared drivers (make_sandbox / stub_gh / run_reconcile and the sandbox cleanup
# trap) live in tests/lib/label-vocab-reconcile-sandbox.sh. The explicit
# FRAGMENTS list below fixes the source order and is guarded in BOTH directions,
# so an unwired fragment cannot silently contribute zero tests and a listed file
# that was renamed away fails loudly instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# These four are read by the FRAGMENTS, not by this file — hence the directive,
# block-scoped because a bare one covers only the next statement.
# shellcheck disable=SC2034
{
    RECONCILE_SH="$REPO_ROOT/bin/label-vocab-reconcile.sh"
    VOCAB_LIB="$REPO_ROOT/bin/lib/label-vocab.sh"
    LINT_SH="$REPO_ROOT/tests/lint-status-label-refs.sh"
    # The real bash, resolved before any PATH is stubbed — a case that puts a shim
    # directory first must still be able to launch the script under test.
    REAL_BASH="$(command -v bash)"
}

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/label-vocab-reconcile-sandbox.sh
source "$SCRIPT_DIR/lib/label-vocab-reconcile-sandbox.sh"

test_suite "status/* label vocabulary reconciler (#938)"

# Fragment source order. NOT the dispatch order below — run_test order is owned
# by the tail and is deliberately not fragment order.
FRAGMENTS="10-comparison.sh 20-fail-loud.sh 30-report-safety.sh 40-temp-files.sh 50-shared-parser.sh"
# shellcheck disable=SC2086  # deliberate word-split: the list is a fixed literal
source_fragments "$SCRIPT_DIR/label-vocab-reconcile" $FRAGMENTS

# --- dispatch ---------------------------------------------------------------

run_fragment_test test_agreeing_vocabularies_pass "control: agreeing vocabularies pass"
run_fragment_test test_declared_label_absent_from_repo_fails "direction 1: a declared label deleted from the repo fails"
run_fragment_test test_every_missing_label_is_named "direction 1: every missing label is named, not just the first"
run_fragment_test test_undeclared_live_label_fails "direction 2: an undeclared live status/* label fails"
run_fragment_test test_all_status_labels_deleted_is_a_finding_not_a_runtime_error "direction 1: the whole family deleted is drift, not a runtime error"
run_fragment_test test_both_directions_reported_together "both directions are reported in one run"
run_fragment_test test_non_status_live_labels_are_ignored "the status/ filter ignores other live label families"
run_fragment_test test_non_status_declared_labels_are_ignored "the status/ filter ignores other declared labels"
run_fragment_test test_missing_gh_exits_two "fail loud: absent gh exits 2, never 0"
run_fragment_test test_failing_gh_exits_two "fail loud: failing gh exits 2, never 1"
run_fragment_test test_empty_gh_output_exits_two "fail loud: gh returning no labels exits 2"
run_fragment_test test_empty_declared_vocabulary_exits_two "fail loud: an empty declared vocabulary exits 2"
run_fragment_test test_missing_plugins_dir_exits_two "fail loud: an absent plugins/ exits 2"
run_fragment_test test_unknown_argument_is_rejected "usage: an unknown argument is rejected before any work"
run_fragment_test test_truncated_label_list_exits_two "fail loud: a possibly-truncated label list exits 2"
run_fragment_test test_label_list_below_the_limit_is_not_truncation "the truncation guard does not fire below the limit"
run_fragment_test test_markdown_in_a_live_label_name_is_neutralized "a live label name cannot inject markdown into the report"
run_fragment_test test_backtick_and_newline_in_a_label_name_are_neutralized "a backtick in a label name cannot break its code span"
run_fragment_test test_a_multiline_label_name_cannot_open_a_heading "a multi-line label name cannot open a heading (via the status/ filter)"
run_fragment_test test_md_safe_collapses_a_tab_in_a_live_label_name "md_safe collapses a tab, driven through the real script"
run_fragment_test test_gh_err_temp_file_is_cleaned_on_gh_failure_paths "the stderr temp file is cleaned on gh's own failure paths"
run_fragment_test test_parser_ignores_trailing_comments_and_quotes "the shared parser trims trailing comments and quotes"
run_fragment_test test_a_hash_inside_a_label_name_is_not_a_comment "a # inside a label name is not a comment"
run_fragment_test test_first_temp_file_is_cleaned_when_second_mktemp_fails "the trap re-arm: no temp file is orphaned by a later mktemp failure"
run_fragment_test test_refactored_offline_gate_still_enforces_both_rules "the refactored offline gate is EXECUTED, not grepped"
run_fragment_test test_preflight_list_matches_its_own_derivation "the preflight list matches the derivation its comment documents"
run_fragment_test test_missing_tr_fails_loud_instead_of_blanking_a_label "an absent tr fails loud instead of blanking a label"
run_fragment_test test_autolink_in_a_label_name_is_neutralized "a bare url in a label name cannot become an autolink"
run_fragment_test test_bidi_override_in_a_label_name_is_neutralized "a bidi override in a label name cannot reverse the report (#999)"
run_fragment_test test_zero_width_chars_in_a_label_name_are_neutralized "zero-width/isolate/BOM characters are made visible (#999)"
run_fragment_test test_ordinary_non_ascii_in_a_label_name_still_renders "ordinary non-ASCII still renders — not reject-all-non-ASCII (#999)"
run_fragment_test test_shared_library_is_syntactically_valid "every shipped script parses (a comment apostrophe can break the awk block)"
run_fragment_test test_reconciler_missing_shared_parser_exits_two "the reconciler's OWN missing-parser guard exits 2 (the twin)"
run_fragment_test test_step_summary_mirrors_stdout "findings reach GITHUB_STEP_SUMMARY, not only stdout"
run_fragment_test test_all_md_safe_metacharacters_are_neutralized "all thirteen md_safe metacharacters are neutralized"
run_fragment_test test_shared_parser_is_the_only_parser "one parser: neither caller carries a copy"
run_fragment_test test_both_callers_derive_the_same_vocabulary "one parser: both callers derive the same vocabulary"
run_fragment_test test_workflow_is_dispatchable_and_informational "the workflow is dispatchable and cannot red a PR"
run_fragment_test test_offline_gate_names_its_other_half "each half names the other (AC5)"

generate_report
