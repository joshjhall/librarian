#!/usr/bin/env bash
# Negative-fixture coverage for the four scan categories AND the project
# skip-policy override in pre-review-gates.sh (issue #83).
#
# plugins/workflow/skills/ship-issue/pre-review-gates.sh is the
# deterministic pre-scan /ship-issue runs before PR creation. It emits
# TSV findings (file\tline\tcategory\tevidence\tcertainty) in four categories —
# ai-slop, debug-statement, missing-test-file, untested-public-api — and merges
# a project .claude/pre-review.yml into the bundled test-skip-patterns.default
# via load_test_skip_policy (lines 40-76), using `git check-ignore` to match.
#
# tests/validate-prescans.sh already pins the EMPTY-LIST / MISSING-ARG contract
# for every pre-scan; it does NOT prove any detector fires or that the
# skip-policy override is honored. A regression that silently muted a detector,
# or made the project YAML a no-op, would ship unnoticed. This gate is the
# additive negative-fixture half: it feeds each detector a fixture engineered to
# trip it and asserts the right category row appears with the right TSV shape,
# proves a clean file stays silent, and proves a project pre-review.yml override
# pattern actually suppresses a finding.
#
# The skip-policy case runs the REAL script inside a fresh `git init` sandbox
# with git's hook-exported environment scrubbed — pre-review-gates.sh resolves
# _PROJECT_ROOT via `git rev-parse --show-toplevel` to find .claude/pre-review.yml
# and the repo-rooted tests/ tree, so a leaked GIT_DIR under a `git push`
# pre-push hook would otherwise pin _PROJECT_ROOT to the OUTER librarian checkout
# (its real tests/ tree and absent pre-review.yml would corrupt the assertions).
# This mirrors tests/validate-golem-scripts.sh, the precedent for that scrub.
#
# Pure bash + coreutils + git, reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.
#
# THIS FILE IS A THIN ENTRY POINT (#895, following #564). The cases live in
# per-area fragments under tests/pre-review-gates/, and the shared drivers
# (run_gate / run_gate_in / new_git_sandbox / make_list / fresh_dir / field /
# category_rows) live in tests/lib/pre-review-gates-sandbox.sh. The explicit
# FRAGMENTS list below fixes the source order and is guarded in both directions,
# so an unwired fragment cannot silently contribute zero tests.
#
# The run_test order below is the DISPATCH order and is deliberately not
# fragment order — it is preserved verbatim from the pre-split monolith.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# GATE / REAL_BASH / GIT_SCRUB are read by tests/lib/pre-review-gates-sandbox.sh
# and the area fragments, all sourced below — shellcheck analyses one file at a
# time and cannot see those uses. Block-scoped: a bare directive would cover only
# the next statement.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
{
    GATE="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"

    # Resolve the real bash once so child invocations work regardless of PATH.
    REAL_BASH="$(command -v bash)"

    # Git's hook-exported environment — scrub per invocation so each sandbox is
    # hermetic even under a pre-push hook (see validate-golem-scripts.sh).
    GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    # The real check-security scanner (#708). Fixtures that run the gate from a
    # SHADOW directory defeat its relative resolution, so any such case that is
    # not itself testing the security arm must pin this — otherwise it goes red
    # for the security arm's reason instead of its own.
    SECURITY_SCANNER_REAL="$REPO_ROOT/plugins/review-audit/skills/check-security/patterns.sh"
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# shellcheck source=tests/lib/pre-review-gates-sandbox.sh
source "$SCRIPT_DIR/lib/pre-review-gates-sandbox.sh"
# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"

test_suite "pre-review-gates scan categories + skip policy (#83)"

# Module-level scratch dir, cleaned up once when the suite exits. Defined here
# rather than in a fragment: the EXIT trap must be installed once for the suite,
# and several fragments read WORKDIR.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Explicit ORDERED fragment list — never a glob (tests/lib/fragments.sh).
FRAGMENTS="10-ai-slop.sh
20-debug-statement.sh
30-missing-test-file.sh
40-untested-public-api.sh
50-selectivity-skip-policy.sh
60-shell-source.sh
70-missing-sibling.sh
80-input-guard.sh
90-evidence-fidelity.sh
95-test-discovery-literals.sh
96-portability.sh
97-sizing.sh
98-security.sh"

# shellcheck disable=SC2086  # deliberate word-splitting: FRAGMENTS is a list
source_fragments "$SCRIPT_DIR/pre-review-gates" $FRAGMENTS

# --- Run All Tests ----------------------------------------------------------
# Order preserved verbatim from the pre-split monolith. run_fragment_test names
# the defining fragment in the failure line (#564).

run_fragment_test test_ai_slop_fires "ai-slop detector fires on a hedging phrase with a 5-column HIGH row"
run_fragment_test test_debug_statement_fires "debug-statement detector fires on a top-level console.log"
run_fragment_test test_ai_slop_skips_scanner_pattern_literals "ai-slop skips a scanner's own pattern literal, but not prose in the same file (#599)"
run_fragment_test test_debug_statement_fires_on_regex_shaped_argument "debug-statement fires on a console.log whose argument contains regex-shaped text (#604)"
run_fragment_test test_debug_statement_fires_on_python_regex_argument "debug-statement fires on a print() whose argument contains re.search(r\"...\") (#604)"
run_fragment_test test_indented_scanner_pattern_literal_does_not_self_match "an indented scanner pattern literal self-matches no debug arm — anchoring, not a guard (#604)"
run_fragment_test test_ai_slop_skips_test_files "ai-slop skips test files (fixture generators), control in real source still fires (#599)"
run_fragment_test test_missing_test_file_fires "missing-test-file detector fires (line 1, HIGH) for an orphan source"
run_fragment_test test_repo_rooted_js_test_detected "repo-rooted tests/ + cross-extension test suppresses missing-test-file (#555)"
run_fragment_test test_repo_rooted_stem_forms_all_match "all 18 stem x suffix alternatives + every extension + reverse cross-extension match (#555)"
run_fragment_test test_repo_rooted_probe_rejects_foreign_extensions "the js/ts extension allowlist is a real filter — a same-stem .py does not match (#555)"
run_fragment_test test_repo_rooted_probe_ignores_directories "a directory named like a test does not suppress missing-test-file (#555)"
run_fragment_test test_colocated_js_test_still_detected "colocated <name>.test.js still suppresses missing-test-file (#555 regression)"
run_fragment_test test_repo_rooted_probe_is_name_anchored "repo-rooted probe stays name-anchored — unrelated tests/ files don't count (#555)"
run_fragment_test test_real_repo_workflow_js_not_flagged "this repo's ship-issue/workflow.js: no missing-test-file, untested-public-api still fires (#555 AC#3)"
run_fragment_test test_is_test_file_anchors_on_basename "is_test_file anchors name arms on the BASENAME — a test_-prefixed DIRECTORY does not skip source (#568)"
run_fragment_test test_is_test_file_true_branch_all_arms "is_test_file TRUE branch: every segment and basename arm skips (#605)"
run_fragment_test test_is_test_file_false_branch_near_misses "is_test_file FALSE branch: contest.py / latest.js / protest/ are not tests (#605)"
run_fragment_test test_declared_test_conventions_honored "declared test_patterns/test_discovery are honored, control still fires (#568)"
run_fragment_test test_test_patterns_works_without_discovery "test_patterns works ALONE and does not stand in for discovery (#568)"
run_fragment_test test_test_discovery_works_without_patterns "test_discovery works ALONE and does not classify the test file (#568)"
run_fragment_test test_hostile_basename_does_not_break_scan "a whitespace/glob-bearing basename degrades cleanly, no abort (#568)"
run_fragment_test test_no_config_means_no_declared_behavior "with no pre-review.yml the declared-convention path is inert (#568)"
run_fragment_test test_stdout_is_output_exempts_prints "stdout_is_output exempts print(), breakpoints STILL fire (#680)"
run_fragment_test test_stdout_is_output_js_mirror "stdout_is_output exempts console.log, the debugger keyword STILL fires (#680)"
run_fragment_test test_stdout_is_output_go_and_java "stdout_is_output exempts fmt.Println/System.out.println too (#680)"
run_fragment_test test_declared_pattern_repos_are_cleaned_up "the EXIT trap reclaims every declared-pattern temp repo (#680)"
run_fragment_test test_stdout_is_output_undeclared_file_still_fires "stdout_is_output exempts only what it names (#680)"
run_fragment_test test_stdout_is_output_inert_without_config "with no pre-review.yml stdout_is_output is inert (#680)"
run_fragment_test test_stdout_is_output_does_not_leak_into_test_categories "stdout_is_output does not suppress missing-test-file (#680)"
run_fragment_test test_mjs_recognized_as_source ".mjs/.cjs route through the js/ts arm, not the unknown-type arm (#568)"
run_fragment_test test_mjs_debug_statement_parity "a .mjs/.cjs console.log is flagged like a .js one — no silent category gap (#568)"
run_fragment_test test_cross_directory_untested_public_api "untested-public-api sees a repo-rooted test, and still checks the SYMBOL (#568)"
run_fragment_test test_untested_public_api_fires "untested-public-api detector fires and names the function"
run_fragment_test test_py_cross_directory_untested_public_api "py: a repo-rooted test suppresses, an unreferenced def in the same file still fires (#600 AC#1/AC#2)"
run_fragment_test test_py_symbol_probe_excludes_fixtures "py: a symbol named only under tests/fixtures/ is not coverage (#600)"
run_fragment_test test_py_symbol_probe_excludes_markdown "py: a symbol named only in a tests/*.md doc is not coverage (#600)"
run_fragment_test test_py_colocated_test_still_detected "py: a colocated test_<name>.py still suppresses (#600 regression)"
run_fragment_test test_py_candidate_path_with_spaces "py: a space-bearing candidate path is grepped, not word-split (#600)"
run_fragment_test test_py_declared_discovery_join "py: a DECLARED test_discovery path joins the candidate list, control still fires (#600)"
run_fragment_test test_py_main_guarded_helper_not_public_api "py: a main()-guarded helper is not public API; a plain-module export still fires (#606 AC#1/AC#2)"
run_fragment_test test_py_nested_main_guard_does_not_gate_module "py: an INDENTED __main__ guard does not gate the module (#606)"
run_fragment_test test_py_dunder_all_overrides_main_guard "py: __all__ overrides the main() guard in both directions (#606)"
run_fragment_test test_py_single_line_dunder_all_does_not_overrun "py: a single-line __all__ terminates on its own bracket (#606)"
run_fragment_test test_py_multiline_dunder_all_collects_all_names "py: a multi-line __all__ collects every listed name (#606)"
run_fragment_test test_py_annotated_dunder_all_recognized "py: an ANNOTATED __all__ (list[str] = ...) is recognized (#606)"
run_fragment_test test_py_dunder_all_membership_is_whole_word "py: __all__ membership is whole-word, not substring (#606)"
run_fragment_test test_go_arm_unaffected_by_py_symbol_gate "go: the py symbol gate does not leak into the go arm (#606)"
run_fragment_test test_real_repo_patterns_py_emit_no_untested_public_api "this repo's patterns.py files emit zero untested-public-api rows (#606 AC#3)"
run_fragment_test test_go_cross_directory_untested_public_api "go: a repo-rooted *_test.go suppresses, an unreferenced export still fires (#600 AC#4)"
run_fragment_test test_go_declared_discovery_join "go: a DECLARED test_discovery path joins the candidate list, control still fires (#600)"
run_fragment_test test_go_probe_excludes_fixtures "go: a *_test.go under tests/fixtures/ is not coverage and does not arm the gate (#600)"
run_fragment_test test_go_unrelated_tests_tree_does_not_arm_the_gate "go: a populated but go-less tests/ tree does not arm the candidate gate (#600 regression)"
run_fragment_test test_go_stays_silent_without_any_candidate "go: no candidate test anywhere means no row — the conservative contract holds (#600)"
run_fragment_test test_clean_source_silent "a clean, tested, private-only source emits no findings"
run_fragment_test test_skip_policy_override_honored "project pre-review.yml override suppresses a skipped path, not a control"
run_fragment_test test_sh_missing_test_fires_and_convention_silences "an untested .sh fires; tests/validate-<name>.sh silences it (#598 AC#1/AC#2)"
run_fragment_test test_sh_stem_forms_all_match "all 6 stems x 3 forms x both extensions match (#598)"
run_fragment_test test_sh_exact_and_fragment_arms_match "exact same-name and NN-<name> split-suite fragment arms match (#598)"
run_fragment_test test_sh_stripped_candidate_is_exact_only "the hyphen-stripped candidate is exact-only — no wildcard false negative (#598)"
run_fragment_test test_sh_stripped_candidate_strips_one_segment "the stripped candidate removes ONE segment, not all (#598)"
run_fragment_test test_bash_source_is_scanned "a .bash SOURCE routes through the sh|bash arm, colocated and repo-rooted (#598)"
run_fragment_test test_sh_colocated_hyphen_form_matches "the colocated list accepts the hyphen test-<name> form (#598)"
run_fragment_test test_sh_probe_ignores_directories "a directory named like a shell test does not suppress the finding (#598)"
run_fragment_test test_sh_probe_excludes_fixtures "a same-named file under tests/fixtures/ is not a test (#598)"
run_fragment_test test_sh_probe_is_name_anchored "the shell probe stays name-anchored (#598)"
run_fragment_test test_sh_skip_and_category_boundaries "*.zsh still skipped; .sh emits no untested-public-api but does emit missing-test-file (#598)"
run_fragment_test test_real_repo_sh_sources_not_flagged "this repo's own convention-covered shell sources are not flagged (#598 AC#3)"
run_fragment_test test_py_repo_rooted_foreign_test_detected "py: a repo-rooted SHELL gate suppresses; an uncovered .py in the same run still fires (#644 AC#1/AC#4)"
run_fragment_test test_py_foreign_probe_requires_content_anchor "py: a name-matching shell test that never mentions the .py does not suppress (#644)"
run_fragment_test test_py_foreign_probe_is_name_anchored "py: the foreign probe stays name-anchored — no constant resolves for every source (#644 AC#3)"
run_fragment_test test_py_foreign_probe_excludes_fixtures "py: tests/fixtures/** is not coverage for the foreign probe (#644)"
run_fragment_test test_py_foreign_probe_content_anchor_is_delimited "py: the content anchor is delimited — a superstring does not suppress, a path-qualified mention still does (#644)"
run_fragment_test test_py_foreign_probe_escapes_regex_metacharacters "py: a regex metacharacter in the basename is matched literally (#644)"
run_fragment_test test_real_repo_py_sources_not_flagged "this repo's own bash-gate-covered .py sources are not flagged (#644 AC#1)"
run_fragment_test test_ai_slop_evidence_keeps_trailing_colon "ai-slop evidence keeps a trailing colon (#573)"
run_fragment_test test_untested_api_evidence_keeps_trailing_colon "untested-public-api evidence keeps a trailing colon (#573)"
run_fragment_test test_interior_colons_survive_both_ways "interior colons survive — the fixture-choice trap is pinned (#573)"
run_fragment_test test_literal_test_discovery_does_not_silence "a literal test_discovery entry no longer silences the run (#601 AC#1)"
run_fragment_test test_literal_test_discovery_warns "a literal test_discovery entry warns on stderr, not stdout (#601 AC#2)"
run_fragment_test test_templated_test_discovery_still_resolves "a proper {name} template still resolves and suppresses (#601/#568 regression)"
run_fragment_test test_mixed_test_discovery_keeps_valid_entry "a mixed list drops only the literal, keeping the valid template (#601 AC#3)"
run_fragment_test test_multiple_literals_all_reported "TWO literals are both dropped and both named, alongside a valid template (#601)"
run_fragment_test test_sizing_rows_reach_the_gate_output "sizing rows reach the gate output with a forwarded numstat sidecar (#695)"
run_fragment_test test_sizing_without_numstat_degrades_to_informational "sizing without a sidecar degrades to informational (#695)"
run_fragment_test test_missing_sizing_does_not_abort_the_scan "a missing sizing.sh degrades gracefully (#695)"
run_fragment_test test_security_prescan_rows_reach_the_gate_output "security pre-scan rows reach the gate output (#708 AC#1)"
run_fragment_test test_security_rows_are_high_certainty "security rows are HIGH — the certainty R3-security-high needs (#708)"
run_fragment_test test_security_scanner_absent_fails_loud "an absent security scanner fails LOUD, never a silent clean (#708 AC#2)"
run_fragment_test test_security_scanner_failure_is_not_silence "a FAILING security scanner also fails loud (#708 AC#2)"
run_fragment_test test_security_absent_differs_from_clean "ABSENT and CLEAN differ in BOTH exit code and output (#708 AC#2)"
run_fragment_test test_security_scope_matches_the_gate_file_list "the security pre-scan scope equals the gate's file list, full and narrowed (#708 AC#3)"
run_fragment_test test_security_arm_does_not_perturb_other_scanners "the security arm does not perturb the other scanners (#708)"
run_fragment_test test_security_scanner_resolves_from_installed_layout "the installed-cache probe resolves across MISMATCHED plugin versions (#708)"
run_fragment_test test_security_scanner_prefers_the_lockstep_version "the installed-cache probe prefers the LOCKSTEP version (#708)"
run_fragment_test test_security_scanner_fallback_is_numeric_not_lexicographic "the version fallback is NUMERIC across the digit boundary, not lexicographic (#708)"
run_fragment_test test_security_scanner_unresolvable_branch_names_the_search "the entirely-unresolvable branch names where it searched (#708 AC#2)"
run_fragment_test test_security_scanner_malformed_version_cannot_outrank_a_real_one "a malformed version directory cannot outrank a real version (#919 AC#3)"
run_fragment_test test_security_refusal_preserves_earlier_rows "a security refusal preserves the rows already computed (#708)"
run_fragment_test test_declared_config_suppresses_baseline "control: declared config suppresses the finding (#679)"
run_fragment_test test_read_yaml_list_strips_trailing_whitespace "read_yaml_list strips trailing whitespace after the closing quote (#679 AC#1)"
run_fragment_test test_read_yaml_list_handles_quotes_and_sections "read_yaml_list parses all quote forms and both key sections (#679)"
run_fragment_test test_read_yaml_list_absent_key_is_empty "read_yaml_list is empty-and-quiet for an absent key or file (#679)"
run_fragment_test test_ai_slop_comma_and_stem_alternatives_fire "comma-terminated hedging phrases and the integrat stem fire (#684)"
run_fragment_test test_ai_slop_leading_boundary_still_guards "a hedging phrase inside a longer word still does not fire (#684)"
run_fragment_test test_read_yaml_list_strips_unquoted_trailing_whitespace "read_yaml_list strips trailing whitespace with no quote in front (#684)"
run_fragment_test test_read_yaml_list_preserves_quoted_inner_whitespace "read_yaml_list preserves whitespace inside the quotes (#684)"
run_fragment_test test_config_with_trailing_whitespace_still_applies "a trailing-whitespace config still applies end-to-end (#679 AC#1)"
run_fragment_test test_unquoted_test_discovery_with_trailing_whitespace_resolves "an unquoted test_discovery template with trailing whitespace resolves (#684)"
run_fragment_test test_config_parse_emits_no_stdout_noise "config parsing never contaminates the TSV stdout (#679 AC#3)"
run_fragment_test test_indented_debug_statements_are_found "INDENTED debug statements are found — POSIX class, not GNU \\s (#679 AC#2)"
run_fragment_test test_exported_symbol_name_is_extracted "exported symbol name extracts correctly via ERE alternation (#679 AC#2)"
run_fragment_test test_diff_refusal_strips_unicode_format_chars "the diff refusal strips multi-byte bidi/zero-width chars too (#816)"
run_fragment_test test_diff_refusal_strips_control_bytes "the diff refusal strips control bytes before reflecting the line (#816)"
run_fragment_test test_missing_test_discovery_fails_loud "a missing sibling test-discovery.sh fails loud, never a partial scan (#816)"
run_fragment_test test_diff_input_fails_loud "a diff passed as a file list fails loud, emits no findings (#816 AC#1)"
run_fragment_test test_headerless_diff_body_is_caught "a headerless unified-diff body is refused too (#816 AC#1)"
run_fragment_test test_unresolvable_list_warns_without_failing "an unresolvable file list warns on stderr but exits 0 (#816 AC#2)"
run_fragment_test test_empty_list_stays_silent_on_stderr "an empty list stays silent on STDERR too — the warning is non-empty-gated (#816)"
run_fragment_test test_partially_resolvable_list_does_not_warn "one resolvable path suppresses the warning (#816 AC#2)"
run_fragment_test test_guard_does_not_alter_normal_scan "the guard does not change what a correct invocation reports (#816)"

generate_report
