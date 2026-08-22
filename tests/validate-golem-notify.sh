#!/usr/bin/env bash
# Coverage for the golem Notification-hook producer
# plugins/workflow/hooks/golem-notify.sh (issue #221), which had ZERO tests.
#
# golem-notify.sh is the TTY-free channel that turns a Claude Code `Notification`
# hook firing into one JSON line on the orchestrator's feed. Two behaviours carry
# the risk a silent regression would ship unnoticed:
#   1. the event CLASSIFIER — a message is bucketed into gate|idle|escalation|
#      dead-end (dead-end before escalation before the gate default), so the
#      orchestrator can tell a real permission gate from a transient idle or a
#      judgement call. An inverted/reordered case arm would mislabel a block.
#   2. the no-jq JSON-ESCAPER — when jq is absent the hook hand-rolls the feed
#      line. It MUST still emit valid JSON for an adversarial identifier, or a
#      crafted value could break out of the string literal and corrupt the feed.
#
# Reachability note for the no-jq escaper: on the jq-less path the hook never
# parses `.message` from stdin (it stays the literal default "awaiting permission
# decision"), so the only attacker-influenceable field reaching the hand-rolled
# encoder is `$GOLEM_ID` (interpolated verbatim when it matches `golem-*`). This
# suite therefore drives the escaper through a GOLEM_ID carrying an embedded
# double-quote and backslash, and asserts the line is still valid JSON with the
# backslash dropped and the quote escaped — exactly what the encoder promises.
#
# Test shape mirrors tests/validate-golem-scripts.sh: each case runs the REAL
# hook inside a fresh `git init` sandbox under a module-level `mktemp -d`, with
# git's hook-exported environment scrubbed (GIT_DIR/…): unscrubbed, they pin the
# hook's git-common-dir to the OUTER repo when the suite runs from a `git push`
# pre-push hook, so the feed would land in the librarian checkout, not the
# sandbox (the failure mode root-caused in golem-gate-watch, PR #62). HOME is
# repointed at the sandbox defensively; the hook writes only under the sandbox.
#
# Pure bash + coreutils + git (+ jq for the classifier/validation cases, which
# skip cleanly when jq is absent), reached via absolute /usr/bin/* paths per
# project convention. Uses the shared harness assertions.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-area
# fragments under tests/golem-notify/, and the shared drivers (new_sandbox /
# run_notify / the curl-stub sink plumbing) live in
# tests/lib/golem-notify-sandbox.sh. The explicit FRAGMENTS list below fixes the
# source order and is guarded, so an unwired fragment cannot silently contribute
# zero tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Read by tests/lib/golem-notify-sandbox.sh and the area fragments, both sourced
# below — shellcheck analyses one file at a time and cannot see those uses.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
NOTIFY="$REPO_ROOT/plugins/workflow/hooks/golem-notify.sh"

# config.sh is the SINGLE SOURCE the hook's inlined GOLEM_WORKTREE_DIR /
# GOLEM_STATUS_DIR default chain is copied from (deliberately not sourced — see
# the hook header). The drift guard in tests/golem-notify/30-status-dir.sh pins
# the two together (#424) — that sourced fragment is the consumer shellcheck
# cannot see from here.
# shellcheck disable=SC2034  # consumed by the sourced fragments, not by this file
CONFIG_SH="$REPO_ROOT/plugins/workflow/scripts/config.sh"

# Resolve the real bash once so the no-jq case (which strips PATH) still finds an
# interpreter.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-scripts.sh).
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# The hook now resolves its feed under GOLEM_STATUS_DIR / GOLEM_WORKTREE_DIR
# (#405). Every default-path helper below expects the unset default
# (.worktrees/.status), so scrub both from the child env — otherwise an operator
# (or this worktree, which exports GOLEM_STATUS_DIR) running the suite with an
# override set would redirect the feed out from under the fixed read-back path
# and fail the whole suite. The override test sets GOLEM_STATUS_DIR explicitly
# after this scrub, so it is unaffected.
#
# GOLEM_EVENT_SINKS / GOLEM_EVENT_SINK_TIMEOUT (#406) are scrubbed for the same
# reason: an operator (or this worktree) running the suite with a sink configured
# would fire real network POSTs from every default-path case and could fail the
# no-network assertion. The sink-fan-out tests set GOLEM_EVENT_SINKS explicitly
# after this scrub, so they are unaffected.
#
# AGENT_ID is scrubbed for a THIRD reason, new with #744: the hook now reads it
# as rung 3 of the golem-id ladder. Running this suite inside a container golem
# (where AGENT_ID=agentNN is exported) would otherwise let the ambient value
# satisfy rung 3 and derive `agentNN` where a test expects the `golem-?`
# placeholder — a real assertion failing on environment alone. The AGENT_ID
# cases below set it explicitly after this scrub, so they are unaffected.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments, not by this file
GOLEM_SCRUB=(GOLEM_STATUS_DIR GOLEM_WORKTREE_DIR GOLEM_EVENT_SINKS GOLEM_EVENT_SINK_TIMEOUT
    AGENT_ID)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-notify.sh Notification hook (#221)"

# --- Shared plumbing + area fragments ---------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/golem-notify-sandbox.sh
source "$SCRIPT_DIR/lib/golem-notify-sandbox.sh"

source_fragments "$SCRIPT_DIR/golem-notify" \
    10-classifier.sh \
    20-no-jq-escaper.sh \
    30-status-dir.sh \
    40-http-sinks.sh \
    50-golem-id.sh

# --- Run all tests ----------------------------------------------------------

# Every sandbox needs git. Gate it from inside a run_test-dispatched body so the
# counters stay consistent (skip_test is designed for within-test use).
git_unavailable() { ! command -v git >/dev/null 2>&1; }

test_git_available() {
    if git_unavailable; then
        skip_test "git not available — cannot build sandbox repos"
        return
    fi
    assert_true "command -v git" "git is available for sandbox construction"
}

run_test test_git_available "git is available (suite prerequisite)"

if git_unavailable; then
    generate_report
    exit $?
fi

run_fragment_test test_classifier_idle "classifier: waiting-for-input → idle"
run_fragment_test test_classifier_idle_no_your "classifier: waiting-for-input (no \"your\") → idle arm 2"
run_fragment_test test_classifier_escalation "classifier: ESCALATION: → escalation"
run_fragment_test test_classifier_dead_end "classifier: DEAD-END: → dead-end"
run_fragment_test test_classifier_resolved "classifier: RESOLVED: → resolved (#422)"
run_fragment_test test_classifier_resolved_midmessage_stays_gate "classifier: mid-message 'resolved:'/'unresolved:' stays gate, not masked (#422)"
run_fragment_test test_classifier_reaped "classifier: REAPED: → reaped (#446)"
run_fragment_test test_classifier_reaped_midmessage_stays_gate "classifier: mid-message 'reaped:' stays gate, not masked (#446)"
run_fragment_test test_classifier_gate_default "classifier: unrecognized message → gate default"
run_fragment_test test_classifier_askuserquestion_stays_gate "classifier: AskUserQuestion permission message → gate default (#321)"
run_fragment_test test_classifier_dead_end_beats_escalation "classifier: dead-end wins over escalation"
run_fragment_test test_no_jq_escaper_emits_valid_json "no-jq escaper: quote+backslash GOLEM_ID stays valid JSON"
run_fragment_test test_no_jq_still_writes_gate_line "no-jq: still writes a valid gate feed line, exits 0"
run_fragment_test test_status_dir_override_honored "status-dir: GOLEM_STATUS_DIR override moves the feed path (#405)"
run_fragment_test test_status_dir_default_unchanged "status-dir: GOLEM_STATUS_DIR unset still lands at .worktrees/.status (#405)"
run_fragment_test test_status_dir_composed_from_worktree_dir "status-dir: GOLEM_WORKTREE_DIR-only override composes <dir>/.status (#424)"
run_fragment_test test_defaults_match_config_sh "drift-guard: hook inlined defaults match config.sh (#424)"
run_fragment_test test_event_sink_defaults_match_config_sh "drift-guard: sink-var inlined defaults match config.sh (#406)"
run_fragment_test test_sinks_empty_no_network "sinks: empty GOLEM_EVENT_SINKS makes no curl call (#406 AC2)"
run_fragment_test test_sinks_fanout_same_payload "sinks: fan same payload to two sinks + feed (#406 AC1/AC4)"
run_fragment_test test_sinks_never_block "sinks: a hung sink never blocks the hook (#406 AC3)"
run_fragment_test test_sinks_scheme_guard "sinks: non-http(s) entry skipped, https sibling POSTed (#406)"
run_fragment_test test_sinks_comma_separated "sinks: comma-separated list fans to both sinks (#406)"
run_fragment_test test_sinks_curl_absent_degrades "sinks: curl absent + sinks set degrades gracefully (#406)"
run_fragment_test test_sinks_fire_when_feed_unwritable "sinks: HTTP fan fires even when feed dir unwritable (#406 AC1)"
run_fragment_test test_golemid_issue_basename "golem-id: issue-N basename → golem-N"
run_fragment_test test_golemid_golem_passthrough "golem-id: golem-* basename passes through"
run_fragment_test test_golemid_placeholder "golem-id: unmatched basename → golem-? placeholder"
run_fragment_test test_golemid_issue_basename_from_subdir "golem-id: issue-N from a subdir → golem-N (cwd-independent)"
run_fragment_test test_golemid_agent_id_resolves "golem-id: AGENT_ID → bare agentNN, not golem-? (#744)"
run_fragment_test test_golemid_golem_id_outranks_agent_id "golem-id: GOLEM_ID (rung 1) outranks AGENT_ID (rung 3) (#744)"
run_fragment_test test_golemid_worktree_outranks_agent_id "golem-id: issue-N root (rung 2) outranks AGENT_ID (rung 3) (#744)"
run_fragment_test test_golemid_golem_basename_outranks_agent_id "golem-id: golem-* root (rung 2) outranks AGENT_ID (rung 3) (#744)"
run_fragment_test test_golemid_empty_agent_id_falls_through "golem-id: empty AGENT_ID falls through to golem-? (#744)"
run_fragment_test test_golemid_agent_id_nojq_sanitized "golem-id: no-jq escaper sanitizes a hostile AGENT_ID (#744)"

generate_report
