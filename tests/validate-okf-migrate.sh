#!/usr/bin/env bash
# okf-migrate behavioral gate (issue #671).
#
# okf-migrate is the OKF toolset's MIGRATION engine — the slice that changes a
# bundle rather than reporting on it. This gate pins the properties that make a
# writing tool safe to hand a repo:
#
#   * THE MODE SPLIT. `check` is the default, `plan` writes nothing, and `apply`
#     needs BOTH an explicit subcommand and --confirm. A tool whose dangerous
#     mode is reachable by accident has no safety model at all.
#   * REVERSIBILITY, against the REAL validator. After `apply`, running
#     check-okf-conformance over the result yields ZERO rows for that category.
#     This is the assertion that makes a transform's claim falsifiable — a
#     stand-in would only prove the engine agrees with itself.
#   * IDEMPOTENCE. Applying twice equals applying once, byte-compared.
#   * THE REFUSALS. Ambiguous `type` inference, a dirty tree, and the two
#     plan-only transforms each refuse AND WRITE NOTHING. Every refusal fixture
#     asserts the tree is unchanged, not merely that the exit code was non-zero:
#     "it errored" and "it errored before writing" are different claims, and
#     only the second is a safety property.
#
# WHY THIS SUITE EXISTS SEPARATELY from tests/validate-python-ports.sh. That
# gate's contract is FILE-LIST shaped (argv[1] is a list of paths; no args ->
# exit 1; empty list -> exit 0 silent), and its scope rule says in as many words
# that a port with a different CLI shape must be pinned by its own suite rather
# than bent to fit. A mode-shaped CLI is exactly that case — the same call
# split-verify.{py,sh} made. So bash<->python parity is asserted HERE, per case,
# across all three modes including a byte-compare of the applied tree.
#
# SKIPS (does not fail) the python assertions when a python3>=3.11 is
# unavailable — the same posture as validate-okf-detectors.sh. The bash path is
# still asserted, and the reversibility checks (which drive the validator's
# python impl) skip with it.
#
# Pure bash-3.2 + coreutils; full command paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/okf-migrate-sandbox.sh
source "$SCRIPT_DIR/lib/okf-migrate-sandbox.sh"

test_suite "okf-migrate migration engine (#671)"

# Consts the FRAGMENTS read; block-scoped because a bare shellcheck directive
# covers only the next statement.
{
    # shellcheck disable=SC2034
    SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/okf-migrate"
    # shellcheck disable=SC2034
    OKF_MIGRATE_PY="$SKILL_DIR/migrate.py"
    # shellcheck disable=SC2034
    OKF_MIGRATE_SH="$SKILL_DIR/migrate.sh"
    # shellcheck disable=SC2034
    OKF_VALIDATOR_PY="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.py"
    # shellcheck disable=SC2034
    OKF_TEST_VERSION="0.2"
}

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi
# shellcheck disable=SC2034  # read by fragments
OKF_HAVE_PY="$HAVE_PY"

# Module-level scratch dir, cleaned once when the suite exits. Defined here
# rather than in a fragment: the EXIT trap must be installed once for the suite,
# and every fragment reads WORKDIR.
WORKDIR="$(okf_migrate_workdir)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Explicit ORDERED fragment list — never a glob (tests/lib/fragments.sh).
FRAGMENTS="10-modes.sh
20-adopt-bundle.sh
30-backfill-type.sh
40-wikilinks.sh
50-safety.sh
60-parity.sh
70-move-concept.sh"

# shellcheck disable=SC2086  # deliberate word-splitting: FRAGMENTS is a list
source_fragments "$SCRIPT_DIR/okf-migrate" $FRAGMENTS

# --- Run All Tests ----------------------------------------------------------
# run_fragment_test names the defining fragment in the failure line (#564).

run_fragment_test test_check_is_the_default_mode "a bare invocation runs check — the safe mode is the one you get by accident (AC1)"
run_fragment_test test_plan_writes_nothing "plan renders the change set and leaves the tree untouched (AC2)"
run_fragment_test test_apply_requires_confirm "apply without --confirm refuses at exit 2 and writes nothing (AC1)"
run_fragment_test test_unknown_mode_is_a_usage_error "an unknown mode exits 1 with a usage message"
run_fragment_test test_removed_format_flag_is_rejected "the removed --format flag is rejected as unknown in both runtimes"
run_fragment_test test_absent_bundle_is_silent_exit_zero "a repo with no bundle exits 0 with no output, never an error"
run_fragment_test test_missing_transforms_fragment_fails_loud "a missing transforms sibling fails LOUD in both runtimes, naming the consequence (AC8)"
run_fragment_test test_unresolvable_pin_fails_loud "an unresolvable version pin fails LOUD and non-zero, not a clean empty report"

run_fragment_test test_adopt_creates_declared_index "adopt-bundle creates a bundle-root index.md carrying the pinned okf_version"
run_fragment_test test_adopt_is_idempotent "adopt-bundle never rewrites an existing index.md — applying twice equals once (AC4)"
run_fragment_test test_adopt_indexes_root_level_only "adopt-bundle indexes ROOT-LEVEL concepts only — a nested one would read as dangling (§8)"
run_fragment_test test_adopt_reversibility "after adopt-bundle, the real validator emits no dangling/orphan rows (AC3)"

run_fragment_test test_backfill_lifts_nested_type "backfill-type lifts a nested metadata.type to the top level — the #991 shape"
run_fragment_test test_backfill_infers_from_directory "backfill-type infers from a configured directory rule"
run_fragment_test test_empty_type_is_replaced_not_duplicated "a present-but-empty type is REPLACED in place, never duplicated"
run_fragment_test test_ambiguous_type_requires_a_human "an unmatched type is AMBIGUOUS: exit 3, candidates listed, nothing guessed (AC5)"
run_fragment_test test_ambiguity_blocks_the_whole_apply "one ambiguity blocks the WHOLE apply — no partial migration (AC5)"
run_fragment_test test_foreign_vocabulary_needs_no_code_change "a repo with an entirely different type vocabulary works by CONFIG alone (AC9)"
run_fragment_test test_backfill_reversibility "after backfill-type, the real validator emits zero okf-missing-type rows (AC3)"
run_fragment_test test_backfill_is_idempotent "backfill-type applied twice equals applied once (AC4)"

run_fragment_test test_wikilink_converted_to_configured_form "a resolvable wikilink becomes a bundle-relative markdown link (§6.1)"
run_fragment_test test_unresolvable_target_is_preserved "an unresolvable target is converted to the path it WOULD occupy, never dropped (AC6)"
run_fragment_test test_labelled_wikilink_keeps_its_label "a [[target|label]] keeps the label as the link text"
run_fragment_test test_fenced_wikilink_is_not_rewritten "a wikilink inside a fenced block is sample text and is left alone"
run_fragment_test test_printf_metacharacters_in_content_survive "printf metacharacters in a memory body are carried through verbatim"
run_fragment_test test_literal_tab_in_content_survives "a literal tab in a memory body survives the tab-delimited edit record"
run_fragment_test test_backslash_escape_sequences_in_content_survive "a literal \\t in content is never decoded into a real tab (round-trip safe)"
run_fragment_test test_wikilink_is_idempotent "wikilink-convert applied twice equals applied once (AC4)"
run_fragment_test test_wikilink_reversibility "the converted bundle carries no [[ ]] and the validator stays clean (AC3)"

run_fragment_test test_dirty_tree_refuses "apply refuses a dirty working tree at exit 2 and writes nothing (AC7)"
run_fragment_test test_allow_dirty_escapes "--allow-dirty is the documented escape from the dirty-tree refusal (AC7)"
run_fragment_test test_non_repo_is_not_dirty "a bundle outside any git repo is NOT dirty — the gate is not a portability bug (AC9)"
run_fragment_test test_apply_writes_only_planned_paths "apply touches only paths the plan listed — the plan is the allowlist (AC7)"
run_fragment_test test_multiple_edits_to_one_file_keep_their_order "two transforms on ONE file apply highest-line-first — no shifted or lost lines"
run_fragment_test test_symlinked_concept_is_never_written_through "a .md symlink is never written through — apply stays inside the bundle root (AC7)"
run_fragment_test test_hidden_directories_are_not_part_of_the_bundle "a hidden directory under the bundle root is not part of the bundle, in both runtimes"
run_fragment_test test_plan_only_transform_refuses_apply "a plan-only transform renders in plan and REFUSES apply at exit 2"
run_fragment_test test_plan_only_transforms_are_visible_in_check "both plan-only transforms are NAMED in check output, never silently omitted"
run_fragment_test test_migrate_config_readers_survive_unreadable "the config readers keep their OSError fallbacks and do not shadow transforms.read_lines (#980)"

run_fragment_test test_move_rewrites_every_inbound_link "every inbound link to a moved concept is rewritten — from TWO directories, both link forms (AC3)"
run_fragment_test test_index_pointer_follows_the_move "the index pointer follows the move — a stale one is a silent un-recall (AC4)"
run_fragment_test test_move_into_an_existing_directory_index "a move into an EXISTING directory index appends to it — no regeneration, no orphan"
run_fragment_test test_prose_mentioning_a_filename_does_not_suppress_the_append "prose naming a file in parens is not a link, so it never suppresses the append"
run_fragment_test test_fenced_example_in_the_target_index_does_not_suppress_the_append "a fenced sample in the target index is an EXAMPLE, so it never suppresses the append"
run_fragment_test test_existing_index_without_a_trailing_newline_appends_after_it "an unterminated last line does not shift the insert position (parity)"
run_fragment_test test_appending_three_concepts_keeps_their_order "appending 3+ concepts to an existing index preserves sorted order (highest-line-first interleaving)"
run_fragment_test test_appended_line_keeps_literal_escape_sequences "a literal backslash-n in an appended index line survives, and still repoints"
run_fragment_test test_backslash_in_a_path_keeps_the_operator_hook "a backslash-bearing path keeps its operator hook (ENVIRON, not awk -v)"
run_fragment_test test_fenced_index_line_does_not_route_a_concept "a fenced index line is an EXAMPLE and never routes a concept"
run_fragment_test test_file_and_dir_taxonomy_sources_route_concepts "the file: and dir: taxonomy sources route concepts (not just index:)"
run_fragment_test test_taxonomy_rules_are_first_match_wins "taxonomy rules are FIRST-MATCH-WINS — reversing the order reverses the destination"
run_fragment_test test_malformed_taxonomy_rules_are_skipped_not_fatal "a malformed taxonomy rule is skipped, never fatal, and its siblings still apply"
run_fragment_test test_two_concepts_moving_together_keep_their_relative_link "two concepts moving together keep a valid relative link (recomputed from the LANDING spot)"
run_fragment_test test_symlinked_existing_index_is_never_written_through "a symlinked existing directory index is never written through (write-path guard)"
run_fragment_test test_foreign_index_name_works_by_config_alone "a repo whose index is named differently works by CONFIG alone (AC9 portability)"
run_fragment_test test_symlinked_move_destination_is_skipped "a symlinked destination is planned away — no write-through to an external dir"
run_fragment_test test_symlinked_move_destination_is_skipped_in_python "...and the python runtime agrees, exit code included (parity)"
run_fragment_test test_retarget_skips_a_leading_url_link "retarget_line scans past a leading URL link to the .md target (parity)"
run_fragment_test test_fenced_claim_does_not_displace_the_real_index_line "a fenced example never displaces the real claiming line (parity, both runtimes)"
run_fragment_test test_retarget_line_matches_python_on_adversarial_shapes "retarget_line is byte-identical to its python twin on shapes this bundle lacks"
run_fragment_test test_bracketed_label_does_not_corrupt_either_index "a literal [ inside a link label corrupts neither index (parity, end-to-end)"
run_fragment_test test_bracketed_label_in_a_body_file_is_left_alone "a bracketed label in a BODY file reaches the second parser and is left intact"
run_fragment_test test_claimed_key_lookup_is_exact_not_a_regex "two destinations differing only at a dot each keep their own index line"
run_fragment_test test_read_index_names_resolves_without_a_preloaded_path "read_index_names resolves (and honors the override) with only the skill dir on sys.path"
run_fragment_test test_destination_collision_leaves_the_file_put "a destination collision skips the move and never overwrites the incumbent"
run_fragment_test test_move_is_idempotent "move-concept applied twice equals applied once, byte-compared (AC5)"
run_fragment_test test_move_reversibility "after the move the real validator emits no dangling/orphan rows (AC6)"
run_fragment_test test_move_preserves_git_history "moves use git mv — git log --follow still reaches the pre-move commit (AC7)"
run_fragment_test test_unconfigured_bundle_has_nothing_to_move "an unconfigured repo gets 'nothing to move', exit 0, and moves nothing (AC10)"
run_fragment_test test_move_plan_writes_nothing "plan renders the move as a rename header and writes nothing (AC2)"
run_fragment_test test_move_apply_requires_confirm "apply without --confirm refuses at exit 2 and moves nothing"
run_fragment_test test_move_destination_outside_the_bundle_is_refused "a taxonomy rule aiming outside the bundle root is refused, writing nothing"
run_fragment_test test_neutered_rewriter_fails_the_inbound_fixture "MUTATION: with the inbound-link rewriter neutered, the AC3/AC4 fixtures go stale (AC8)"
run_fragment_test test_move_parity_between_runtimes "bash and python produce byte-identical moved trees"

run_fragment_test test_parity_check_mode "bash and python agree byte-for-byte in check mode"
run_fragment_test test_parity_plan_mode "bash and python agree byte-for-byte in plan mode"
run_fragment_test test_parity_applied_tree "bash and python produce byte-identical APPLIED TREES"
run_fragment_test test_parity_path_containing_a_tab "a filename containing a tab migrates identically in both runtimes"
run_fragment_test test_parity_refusal_exit_codes "bash and python agree on every refusal's exit code"

generate_report
