#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/review-convergence.sh (issue #596).
#
# The script owns the "keep reviewing or stop?" DECISION for the ship-issue
# multi-cycle review loop — the mechanized replacement for the fixed
# `REVIEW_MAX_CYCLES` counter, which #567's 26-cycle batch showed is both too low
# (#533's only blocking finding of the batch arrived in cycle 4) and too high
# (#564 was verifiably clean at cycle 1). A silent regression here re-opens
# exactly that: a wrong verdict either ships a defect the next cycle would have
# caught, or burns cycles on a converged review.
#
# This gate pins the deterministic decision table:
#   - the ordered first-match rule list C1..C8 (each rule reachable, order
#     load-bearing where the plan says it is),
#   - the hard cap always terminating (#596 AC#3),
#   - a partial cycle never reading as converged,
#   - the NARROW-DELTA-ZERO non-stop (#596 AC#2) — the refinement the issue turns
#     on, and the one assertion that makes this gate meaningful,
#   - env overrides moving the surface-comparability boundary,
#   - the fail-loud exit-2 paths (bad flags, bad env, unreadable/malformed JSON).
#
# ANTI-TAUTOLOGY NOTE (#599/#600). Two traps this suite is built to avoid:
#   1. A fixture that passes with AND without the predicate. Every convergence
#      case therefore asserts the exact deciding `rule`, not just `verdict` —
#      `stop` alone is satisfied by the old counter at the cap, so asserting it
#      bare would pass against code that never looked at a finding.
#   2. A pair whose two halves differ in more than the property under test. The
#      C3/C4 pair below is byte-identical apart from `--delta-lines`: SAME result
#      file, same cycle, same cap. A detector that ignores surface returns the
#      same verdict for both, so the pair cannot both pass unless the surface
#      comparison genuinely exists.
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.
#
# THIS FILE IS A THIN ENTRY POINT (issue #1130, convention #564). The cases live
# in per-area fragments under tests/review-convergence/, and the shared fixtures
# (FIXTURES / finding / val) live in tests/lib/review-convergence-sandbox.sh. The
# explicit FRAGMENTS list below fixes the source order and is guarded, so an
# unwired fragment cannot silently contribute zero tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC2034  # consumed by the sourced fragments, not by this file
RC="$REPO_ROOT/plugins/workflow/scripts/review-convergence.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"

test_suite "review-convergence.sh (#596)"

# shellcheck source=tests/lib/review-convergence-sandbox.sh
source "$SCRIPT_DIR/lib/review-convergence-sandbox.sh"

FRAGMENTS_DIR="$SCRIPT_DIR/review-convergence"
FRAGMENTS="10-next-scope.sh
    20-cap-partial.sh
    30-surface.sh
    40-stop-signals.sh
    50-injection.sh
    60-rule-integrity.sh
    70-capped-over.sh
    80-no-signal.sh
    90-charged-warn.sh
    100-integration.sh
    110-fail-loud.sh
    120-provenance.sh"
# shellcheck disable=SC2086  # word-split on purpose: one argument per fragment
source_fragments "$FRAGMENTS_DIR" $FRAGMENTS

run_fragment_test test_cap_stops_even_with_novel_findings "C1: the cap stops a still-productive review"
run_fragment_test test_cap_outranks_partial "C1 outranks C2 (termination guaranteed)"
run_fragment_test test_below_cap_does_not_stop_on_the_counter "cycle 4 with novel findings continues (#533)"
run_fragment_test test_partial_zero_does_not_converge "C2: a partial zero never converges"
run_fragment_test test_partial_refuted_does_not_converge "C2 outranks C5"
run_fragment_test test_unengaged_zero_does_not_converge "C2b: unengaged zero does not stop (#1111)"
run_fragment_test test_unengaged_outranks_refuted_only "C2b outranks C5"
run_fragment_test test_unengaged_is_charged_to_the_cap "C2b is charged; C1 reports it as capped_over"
run_fragment_test test_unengaged_field_absent_or_malformed_reads_zero "absent/malformed unengaged field reads 0"
run_fragment_test test_narrow_delta_zero_does_not_stop "C3: AC#2 narrow-delta zero does NOT stop"
run_fragment_test test_comparable_delta_zero_stops "C4: comparable-surface zero stops"
run_fragment_test test_narrow_and_comparable_zero_differ_only_in_surface "C3/C4 differ only in surface (anti-tautology)"
run_fragment_test test_zero_at_boundary_ratio_stops "C3/C4 boundary is at the ratio exactly"
run_fragment_test test_cycle_one_zero_stops "cycle-1 zero stops immediately (#564)"
run_fragment_test test_surface_ratio_env_override_moves_the_boundary "RATIO override moves the C3/C4 boundary"
run_fragment_test test_refuted_only_stops "C5: refuted-only stops (#555)"
run_fragment_test test_partially_refuted_continues "C5 is ALL, not ANY"
run_fragment_test test_all_duplicate_stops "C6: all-duplicate stops (#533 cycle 5)"
run_fragment_test test_novel_finding_against_prior_continues "C6 matches the finding, not the flag"
run_fragment_test test_partially_duplicate_continues "C6 is ALL, not ANY"
run_fragment_test test_duplicate_matches_across_all_earlier_cycles "C6 matches across all earlier cycles"
run_fragment_test test_recursive_test_machinery_stops "C7: recursive test machinery stops (#498)"
run_fragment_test test_test_file_outside_the_fix_delta_is_not_recursive "C7 keys off delta membership"
run_fragment_test test_mixed_recursive_continues "C7 is ALL, not ANY"
run_fragment_test test_capped_over_names_the_would_be_narrow_zero "capped_over names the concealed C3 (#635 repro)"
run_fragment_test test_capped_over_matches_the_verdict_with_the_cap_lifted "capped_over == the uncapped run's rule"
run_fragment_test test_capped_over_distinguishes_a_corroborated_cap "a cap over a real C4-zero is corroborated"
run_fragment_test test_capped_over_reports_still_productive_material "capped_over reports C8-novel at the cap"
run_fragment_test test_capped_over_reports_a_capped_partial "capped_over reports C2 directly under C1"
run_fragment_test test_capped_over_is_empty_on_a_non_cap_stop "capped_over empty when C1 did not fire"
run_fragment_test test_capped_over_is_emitted_on_every_verdict "capped_over key present on every verdict"
run_fragment_test test_no_signal_cycle_does_not_stop_at_the_cycle_cap "C0b: a crashed cycle does not consume the cap (#616)"
run_fragment_test test_no_signal_pair_differs_only_in_the_flag "C0b pair differs only in no_review_signal (anti-tautology)"
run_fragment_test test_attempt_cap_terminates_a_persistently_crashing_loop "C0: a crashing loop still terminates"
run_fragment_test test_attempt_cap_outranks_everything "C0 outranks C0b, C1 and C2"
run_fragment_test test_no_signal_does_not_affect_an_ordinary_cycle "C0b does not disturb an ordinary cycle"
run_fragment_test test_string_false_is_not_read_as_no_signal "a string flag value is not no-signal"
run_fragment_test test_absent_no_signal_field_reads_as_an_ordinary_cycle "an absent no_review_signal is not no-signal"
run_fragment_test test_non_object_result_fails_loud_not_with_a_jq_crash "a non-object result exits 2, not a bare jq crash"
run_fragment_test test_attempt_defaults_to_cycle_for_an_unmigrated_caller "the new rules are inert for an un-migrated caller"
run_fragment_test test_next_scope_is_narrow_after_blocking "next_scope=narrow after a blocking cycle (#656)"
run_fragment_test test_next_scope_is_full_after_clean "next_scope=full after a clean cycle (#656)"
run_fragment_test test_next_scope_is_full_after_deferrable_only "next_scope=full after deferrable-only (#656)"
run_fragment_test test_next_scope_after_a_crash_is_always_full "next_scope: a crashed cycle always advises full (#656)"
run_fragment_test test_next_scope_handles_a_missing_blocking_key "next_scope: an absent blocking key reads as 0 (#656)"
run_fragment_test test_next_scope_keys_on_bucket_not_count "next_scope keys on the BLOCKING bucket, not finding count (#656)"
run_fragment_test test_next_scope_emitted_on_every_verdict "next_scope is emitted on every verdict incl. the cap paths (#656)"
run_fragment_test test_next_scope_changes_no_existing_verdict "adding next_scope changed no verdict/rule/count (#656)"
run_fragment_test test_clean_then_clean_terminates_in_two_cycles "a clean->clean loop terminates in TWO cycles (#656 AC)"
run_fragment_test test_max_attempts_env_override_moves_the_ceiling "REVIEW_MAX_ATTEMPTS is honored"
run_fragment_test test_every_rule_is_reachable "every rule C1-C8 is reachable"
run_fragment_test test_every_verdict_is_continue_or_stop "verdict is always continue|stop"
run_fragment_test test_counts_are_reported_on_every_verdict "counts reported on every verdict"
run_fragment_test test_deferrable_findings_count_as_material "deferrables count as material (#580)"
run_fragment_test test_loop_terminates_on_a_never_converging_review "a never-converging loop stops at the cap (AC#3)"
run_fragment_test test_loop_terminates_early_on_a_converged_review "a converged loop stops early (AC#1)"
run_fragment_test test_bad_attempt_fails_loud "--attempt 0 -> exit 2"
run_fragment_test test_noninteger_attempt_fails_loud "non-integer --attempt -> exit 2"
run_fragment_test test_bad_max_attempts_fails_loud "--max-attempts 0 -> exit 2"
run_fragment_test test_max_attempts_below_max_cycles_fails_loud "--max-attempts < --max-cycles -> exit 2"
run_fragment_test test_leading_zero_attempt_fails_loud "leading-zero --attempt -> exit 2 (octal guard)"
run_fragment_test test_missing_cycle_fails_loud "missing --cycle -> exit 2"
run_fragment_test test_missing_delta_lines_fails_loud "missing --delta-lines -> exit 2, never defaulted"
run_fragment_test test_missing_max_cycles_fails_loud "missing --max-cycles -> exit 2"
run_fragment_test test_missing_result_fails_loud "missing --result -> exit 2"
run_fragment_test test_zero_cycle_fails_loud "--cycle 0 -> exit 2"
run_fragment_test test_zero_max_cycles_fails_loud "--max-cycles 0 -> exit 2"
run_fragment_test test_negative_delta_lines_fails_loud "negative --delta-lines -> exit 2"
run_fragment_test test_bad_partial_fails_loud "bad --partial -> exit 2"
run_fragment_test test_unreadable_result_fails_loud "unreadable --result -> exit 2"
run_fragment_test test_malformed_result_fails_loud "malformed result JSON -> exit 2"
run_fragment_test test_valid_json_scalar_is_not_misread_as_malformed "jq empty, not jq -e, is the validity probe"
run_fragment_test test_newline_in_file_cannot_forge_a_duplicate "injection: newline in .file cannot forge a C6 stop"
run_fragment_test test_newline_in_file_cannot_forge_a_recursive_match "injection: newline in .file cannot forge a C7 stop"
run_fragment_test test_carriage_return_in_file_cannot_forge_a_recursive_match "injection: CR is normalized like a newline"
run_fragment_test test_newline_in_category_cannot_forge_a_duplicate "injection: newline in .category cannot forge a C6 stop"
run_fragment_test test_colon_in_file_cannot_forge_a_duplicate "injection: colon in .file cannot forge a C6 stop"
run_fragment_test test_colon_in_path_still_matches_for_recursive "colon substitution does not break C7 path matching"
run_fragment_test test_underscore_and_colon_paths_do_not_collide "injective: a:b and a_b do not collide (#618)"
run_fragment_test test_percent_in_path_does_not_collide_with_an_encoded_colon "injective: the escape alphabet is itself injective (#618)"
run_fragment_test test_boolean_false_field_does_not_collide_with_an_absent_one "injective: false does not collide with an absent field"
run_fragment_test test_sanitization_preserves_ordinary_matching "sanitization preserves real duplicate matching"
run_fragment_test test_noninteger_line_start_fails_loud "non-integer line_start -> exit 2 (#619)"
run_fragment_test test_fractional_line_start_fails_loud "fractional line_start -> exit 2 (the floor half, #619)"
run_fragment_test test_null_line_start_is_valid "an omitted line_start is still valid (#619)"
run_fragment_test test_unreadable_prev_result_fails_loud "unreadable --prev-result -> exit 2"
run_fragment_test test_malformed_prev_result_fails_loud "malformed --prev-result -> exit 2"
run_fragment_test test_unreadable_delta_files_is_silently_skipped "missing --delta-files degrades, by design"
run_fragment_test test_bad_ratio_env_fails_loud "bad RATIO env -> exit 2"
run_fragment_test test_leading_zero_numerics_fail_loud "leading-zero numerics -> exit 2 (octal guard)"
run_fragment_test test_plain_zero_delta_lines_is_valid "plain 0 --delta-lines is valid"
run_fragment_test test_prev_result_missing_its_value_fails_loud "--prev-result with no value -> exit 2"
run_fragment_test test_prev_result_as_trailing_token_fails_loud "--prev-result as the LAST argument -> exit 2"
run_fragment_test test_optional_flag_as_trailing_token_fails_loud "--delta-files as the LAST argument -> exit 2"
run_fragment_test test_optional_flag_missing_its_value_fails_loud "--delta-files with no value -> exit 2"
run_fragment_test test_trailing_value_is_not_mistaken_for_a_missing_one "a value in final position still parses"
run_fragment_test test_duplicate_flag_is_first_match_wins "a duplicate flag is first-match-wins (documented)"
run_fragment_test test_empty_string_value_behaves_as_absent "an empty optional value degrades, by design"
run_fragment_test test_unknown_subcommand_fails_loud "unknown subcommand -> exit 2"
run_fragment_test test_no_subcommand_fails_loud "no subcommand -> exit 2"

run_fragment_test test_warn_fires_exactly_when_the_next_full_cycle_is_the_last "warn at cycle+1 == max, not cycle+2 (#1120)"
run_fragment_test test_warn_needs_a_full_next_scope_and_a_continue "warn needs next_scope=full and continue"
run_fragment_test test_warn_accounts_for_an_uncharged_cycle "warn boundary is cycle == max after an uncharged cycle"
run_fragment_test test_warn_is_emitted_on_every_verdict "warn is emitted on every verdict"
run_fragment_test test_warn_fires_when_the_attempt_cap_binds_first "warn fires when the attempt cap binds first"
run_fragment_test test_narrow_zero_is_uncharged_only_with_an_explicit_attempt "C3 uncharged only with explicit --attempt"
run_fragment_test test_every_other_rule_is_charged "every other rule is charged"
run_fragment_test test_observed_sequence_reviews_the_final_fix "#1057 replay: cap lands on a narrow re-check"
run_fragment_test test_uncharged_narrow_zero_loop_is_bounded_by_attempts "uncharged C3 loop is bounded by attempts"

run_fragment_test test_foreign_issue_result_is_refused_not_stopped "a foreign-issue zero is refused, not a C4 stop (#1150 replay)"
run_fragment_test test_result_without_issue_is_refused_when_issue_is_asserted "an unstamped result under --issue is refused (#1150)"
run_fragment_test test_string_issue_does_not_match_the_number "a string issue does not match the integer (#1150)"
run_fragment_test test_foreign_cycle_result_is_refused_with_matching_issue "a right-issue wrong-cycle result is refused (#1150)"
run_fragment_test test_foreign_prev_result_is_refused_on_a_zero_cycle "a foreign --prev-result is refused on a zero cycle (#1150)"
run_fragment_test test_foreign_prev_result_is_refused_among_valid_ones "every --prev-result is checked, not only the first (#1150)"
run_fragment_test test_matching_provenance_yields_a_verdict "matching provenance reaches the rule list (#1150 control)"
run_fragment_test test_missing_issue_is_refused "check without --issue -> exit 2 (#1157)"
run_fragment_test test_missing_run_is_refused "check without --run -> exit 2 (#1157)"
run_fragment_test test_foreign_run_result_is_refused "a same-issue same-cycle other-run result is refused (#1157)"
run_fragment_test test_foreign_run_prev_result_is_refused_on_a_zero_cycle "an other-run --prev-result is refused on a zero cycle (#1157)"
run_fragment_test test_unstamped_run_is_refused "a null or absent run stamp is refused (#1157)"
run_fragment_test test_non_string_run_does_not_match "a numeric run does not match (#1157)"
run_fragment_test test_bad_run_value_fails_loud "a bad --run value -> exit 2 (#1157)"
run_fragment_test test_bad_issue_value_fails_loud "a bad --issue value -> exit 2 (#1150)"
run_fragment_test test_string_cycle_does_not_match_the_number "a string cycle does not match the integer (#1150)"
run_fragment_test test_unusable_prev_result_is_refused_on_a_zero_cycle "a missing/invalid/non-object --prev-result -> exit 2 on a zero cycle (#1150)"
run_fragment_test test_unstamped_prev_result_is_refused_under_issue "an unstamped --prev-result under --issue -> exit 2 (#1150)"
run_fragment_test test_non_object_result_is_refused_under_issue "an array --result under --issue -> exit 2, not a jq crash (#1150)"
run_fragment_test test_null_cycle_result_is_accepted "an explicit null cycle stamp is accepted (#1150)"
run_fragment_test test_recipes_key_the_refusal_exception_on_the_marker "recipes key the refusal exception on refusal=provenance (#1157)"
run_fragment_test test_every_shipped_recipe_passes_issue "every recipe invocation of check passes --issue and --run (#1150, #1157)"

# Every `test_*` function defined in a fragment must actually be dispatched by a
# `run_fragment_test` line above. A test that is written but never registered passes silently by
# not running at all — which is strictly worse than a missing test, because the
# suite's green summary asserts coverage that does not exist. (This gate was added
# after exactly that happened here: test_malformed_prev_result_fails_loud sat
# defined-but-unregistered and the total stayed put at 48.)
#
# Since the split (#1130) the definitions live in tests/review-convergence/ and
# the dispatch lines here, so the two sets are read from those two places. The
# pre-split guard grepped "$0" for both; left unchanged it would compare two
# EMPTY sets and pass while checking nothing — hence the non-empty assertion.
check_every_test_is_registered() {
    # Compare NAME SETS, not counts. A bare count is satisfied by two errors that
    # cancel — registering one test twice while another is never registered keeps
    # the totals equal and the guard green, which is precisely the failure it
    # exists to catch. `comm` on the sorted name lists cannot be fooled that way.
    # This guard itself is dispatched by a plain `run_test check_every_...` line,
    # deliberately outside the `test_*` namespace so it need not count itself.
    local defined registered unregistered undefined
    defined="$(command grep -ho '^test_[a-z_]*() {' "$FRAGMENTS_DIR"/*.sh | command sed 's/() {$//' | command sort -u)"
    registered="$(command grep -o '^run_fragment_test test_[a-z_]*' "$0" | command sed 's/^run_fragment_test //' | command sort -u)"
    unregistered="$(command comm -23 <(command printf '%s\n' "$defined") <(command printf '%s\n' "$registered") | command tr '\n' ' ')"
    undefined="$(command comm -13 <(command printf '%s\n' "$defined") <(command printf '%s\n' "$registered") | command tr '\n' ' ')"
    assert_equals "" "$(command printf '%s' "$unregistered")" \
        "no test_* function is defined but never dispatched (unregistered: $unregistered)"
    assert_equals "" "$(command printf '%s' "$undefined")" \
        "no run_fragment_test dispatches a name that does not exist (undefined: $undefined)"
    assert_not_empty "$defined" \
        "the fragments define test_* functions (guard is not comparing two empty sets)"
}
run_test check_every_test_is_registered "no test is defined-but-unregistered"

generate_report
