#!/usr/bin/env bash
# Behavioral regression test for plugins/workflow/scripts/golem-gate-watch.sh.
#
# Guards issue #24: the feed_snapshot() jq filter called `.ts | fromdateiso8601`
# on every entry. A legacy feed line written before the timestamp convention has
# no `.ts` field, so jq threw `strptime/1 requires string inputs and arguments`
# and exited non-zero. The script's `2>/dev/null` swallowed the error and the
# `--once` snapshot returned EMPTY — silently dropping ALL feed-blocked golems
# from the BLOCKED display, including golems carrying valid `gate` events. The
# fix guards the timestamp (`if (.ts|type)=="string" and .ts!="" then ... else
# true end`) so a missing or empty `.ts` line is treated as fresh rather than
# aborting the whole pipeline, while a present-and-stale `.ts` still ages out.
#
# This is the first BEHAVIORAL gate in the suite (the others are structural):
# it builds a throwaway git repo, plants a feed.jsonl, runs the REAL script
# `--once`, and asserts the snapshot. Two cases cover both branches of the fix:
#   1. legacy no-`ts` + valid dated gate -> both survive (the regression)
#   2. a present-but-stale `.ts` outside the TTL window -> excluded (the
#      symmetrical half, so a future refactor dropping the TTL check is caught)
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-area
# fragments under tests/gate-watch/, and the shared drivers
# (_run_once_snapshot / _run_liveness_snapshot* / the pane helpers) live in
# tests/lib/gate-watch-sandbox.sh. The explicit FRAGMENTS list below fixes the
# source order and is guarded, so an unwired fragment cannot silently contribute
# zero tests.
#
# Pure bash + coreutils + git + jq; skips cleanly when jq is absent
# (feed_snapshot itself no-ops without jq). GOLEM_WORKTREE_DIR/GOLEM_STATUS_DIR
# are pinned at the invocation site so an exported value from a live golem
# session or a project `.envrc` cannot redirect the script to a real feed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The script under test. Read by tests/lib/gate-watch-sandbox.sh and the area
# fragments, both sourced below — shellcheck analyses one file at a time and so
# cannot see those uses.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
GATE_WATCH="$REPO_ROOT/plugins/workflow/scripts/golem-gate-watch.sh"

test_suite "golem-gate-watch feed snapshot + liveness + helpers (#24, #28, #38, #82, #229, #248, #446, #447, #489)"
# --- Shared drivers + area fragments ----------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/gate-watch-sandbox.sh
source "$SCRIPT_DIR/lib/gate-watch-sandbox.sh"

source_fragments "$SCRIPT_DIR/gate-watch" \
    10-feed-snapshot.sh \
    20-liveness.sh \
    30-helpers-and-modes.sh \
    40-stream-dedup.sh

# --- Run all tests ----------------------------------------------------------

run_fragment_test test_legacy_line_does_not_drop_golems "Legacy no-ts feed line does not drop all BLOCKED golems"
run_fragment_test test_stale_ts_gate_ages_out "Stale dated gate ages out while no-ts golem stays fresh"
run_fragment_test test_empty_ts_treated_as_fresh "Empty-string ts is treated as fresh, not a crash"
run_fragment_test test_escalation_surfaces_labelled "Escalation surfaces in BLOCKED, labelled distinctly; idle excluded"
run_fragment_test test_resolved_supersedes_gate "Resolved line supersedes a stale gate; still-gated golem surfaces (#422)"
run_fragment_test test_golem_question_sentinel_excluded "Orphan golem-? sentinel is filtered while a real gate still surfaces (#323)"
run_fragment_test test_jq_absent_is_silent_noop "jq absent from PATH: --once is a silent no-op despite a fresh gate"
run_fragment_test test_liveness_fresh_is_alive "Liveness: fresh-activity golem reports alive (process up), not 'advancing'"
run_fragment_test test_liveness_stale_is_possible_stall "Liveness: old-activity golem flagged a possible stall (exit 0)"
run_fragment_test test_liveness_gated_not_stalled "Liveness: gated golem reported gated, not stalled"
run_fragment_test test_liveness_threshold_env_overridable "Liveness: GOLEM_STALL_THRESHOLD is env-overridable"
run_fragment_test test_liveness_pane_working_wiring "Liveness wiring: working pane -> 'alive, working' (pane wins over mtime)"
run_fragment_test test_liveness_pane_idle_wiring "Liveness wiring: idle pane (#229) -> 'idle at prompt' (pane wins over mtime)"
run_fragment_test test_liveness_pane_died_wiring "Liveness wiring: died pane (#446) -> DIED label with class (pane wins over mtime)"
run_fragment_test test_liveness_pane_indeterminate_falls_through "Liveness wiring: indeterminate pane falls through to mtime heartbeat"
run_fragment_test test_liveness_pane_own_work_wiring "Liveness wiring: own-work-pending pane falls through to mtime heartbeat, not idle (#517)"
run_fragment_test test_liveness_pane_blank_capture_falls_through "Liveness wiring: blank capture-pane (guard false) falls through to mtime heartbeat"
run_fragment_test test_liveness_transcript_working_wiring "Liveness transcript (#248): turn-in-flight -> 'alive, working' (transcript wins over mtime)"
run_fragment_test test_liveness_transcript_idle_wiring "Liveness transcript (#248): turn-ended -> 'idle at prompt' (headless #229 analog)"
run_fragment_test test_liveness_transcript_errored_wiring "Liveness transcript (#248): isApiErrorMessage -> 'errored and idle'"
run_fragment_test test_liveness_transcript_sidechain_not_masking "Liveness transcript (#248): sidechain churn does not mask a top-level idle"
run_fragment_test test_liveness_transcript_missing_falls_through "Liveness transcript (#248): missing transcript falls through to mtime heartbeat"
run_fragment_test test_liveness_transcript_indeterminate_falls_through "Liveness transcript (#248): indeterminate transcript falls through to mtime heartbeat"
run_fragment_test test_unknown_mode_exits_2 "Unknown mode exits 2 with a usage message"
run_fragment_test test_no_arg_defaults_to_once "No argument defaults to --once (not the error path)"
run_fragment_test test_fmt_age_formats "_fmt_age: seconds vs whole-minute formatting"
run_fragment_test test_pane_is_plan_gate "pane_is_plan_gate matches plan overlays, not work output"
run_fragment_test test_pane_is_gate "pane_is_gate matches the generic permission overlay only"
run_fragment_test test_pane_is_fork "pane_is_fork matches the AskUserQuestion escalation fork overlay"
run_fragment_test test_pane_is_fork_footer_anchored "pane_is_fork is footer-anchored (no self-trip on scrolled text)"
run_fragment_test test_pane_fork_plan_precedence "pane_is_plan_gate wins over pane_is_fork on a plan+fork pane"
run_fragment_test test_panes_snapshot_dispatch "panes_snapshot dispatch order + labels (plan/gate/fork) end-to-end"
run_fragment_test test_pane_is_multi_question_form "pane_is_multi_question_form needs BOTH the fork footer and a widget glyph (#467)"
run_fragment_test test_pane_multi_question_form_above_footer "pane_is_multi_question_form detects a tab bar scrolled above the footer (#467)"
run_fragment_test test_pane_multi_question_form_no_self_trip "pane_is_multi_question_form does not self-trip on a working golem's pane (#467)"
run_fragment_test test_pane_multi_question_form_error_window "pane_is_multi_question_form: exact \$pane_error_lines boundary + GOLEM_PANE_ERROR_LINES override (#467)"
run_fragment_test test_pane_multi_question_form_prose_scrollback "pane_is_multi_question_form: glyph-bearing prose in scrollback does not fake a form (#467)"
run_fragment_test test_panes_snapshot_multi_question_dispatch "panes_snapshot: form label wins over the fork label; fork stays plain (#467)"
run_fragment_test test_pane_is_turn_end "pane_is_turn_end matches the turn-ended/idle-at-prompt footer only (#447)"
run_fragment_test test_pane_is_turn_end_footer_anchored "pane_is_turn_end is footer-anchored (no self-trip on scrolled text)"
run_fragment_test test_pane_is_turn_end_pending_own_work "pane_is_turn_end excludes a golem parked on its OWN monitors/workflow; real idle preserved (#517)"
run_fragment_test test_pane_pending_own_work "pane_pending_own_work matches own-work chrome only, not bare-word prose (#517)"
run_fragment_test test_panes_snapshot_turn_end_dispatch "panes_snapshot emits idle-at-prompt as last-resort; overlay wins (#447)"
run_fragment_test test_pane_footer_lines_env_overridable "pane matchers: GOLEM_PANE_FOOTER_LINES is env-overridable both directions (#458)"
run_fragment_test test_confirm_turn_end_debounce "confirm_turn_end: two-consecutive-poll debounce on the idle line; gates immediate (#447)"
run_fragment_test test_pane_liveness_class "pane_liveness_class: spinner=working, error/idle footer=idle, spinner wins"
run_fragment_test test_emit_transitions_dedup "emit_transitions: prime/standing/new/changed/re-gate dedup"
run_fragment_test test_liveness_stabilize_strips_age "liveness_stabilize: mtime age stripped to a stable class; other lines verbatim (#489)"
run_fragment_test test_liveness_stream_dedup "liveness stream: steady state silent, class change emits (#489 AC1/AC2/AC4)"
run_fragment_test test_liveness_summary_counts "liveness_summary: aggregate class counts; empty snapshot silent (#489)"
run_fragment_test test_summary_due "summary_due: cadence gate; 0/non-numeric interval disables (#489)"
run_fragment_test test_summary_enabled "summary_enabled: 0/empty/non-numeric disables the startup summary too (#489)"
run_fragment_test test_summary_interval_env_overridable "GOLEM_LIVENESS_SUMMARY_INTERVAL is env-overridable (#489)"
run_fragment_test test_heartbeat_interval_numeric_coercion "GOLEM_HEARTBEAT_INTERVAL non-numeric coerced to 60, no watch crash (#489)"
run_fragment_test test_ghost_gate_dropped_when_no_trace "Ghost filter: gated golem with no live trace dropped from BLOCKED (#446)"
run_fragment_test test_pane_is_api_error "pane_is_api_error: matches API-error death, spinner vetoes, classifies retriable/terminal (#446)"
run_fragment_test test_panes_snapshot_died_dispatch "panes_snapshot: died-on-API-error emits DIED before turn-end; modal gates still win (#446)"

generate_report
