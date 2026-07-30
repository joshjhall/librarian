# shellcheck shell=bash
# Classifier (jq path) — golem-notify hook tests (issue #564 split).
#
# Covers the event-kind classification the hook emits for each Notification payload shape.
#
# Sourced by tests/validate-golem-notify.sh, which defines NOTIFY / CONFIG_SH /
# REAL_BASH and sources tests/lib/golem-notify-sandbox.sh for the shared drivers
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# --- Classifier (jq path) ---------------------------------------------------

# assert_event <payload> <expected-event> <desc>
# Runs the hook (jq present), asserts exit 0, a valid-JSON feed line, and the
# classified `.event`.
assert_event() {
    local payload="$1" want="$2" desc="$3" sb got
    new_sandbox sb
    run_notify "$sb" "$payload" "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 ($desc)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line is valid JSON ($desc)"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.event' 2>/dev/null || true)"
    assert_equals "$want" "$got" "classified as $want ($desc)"
}

test_classifier_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude is waiting for your input"}' "idle" \
        "waiting-for-input"
}

# The second idle arm — "waiting for input" WITHOUT "your" — matches only
# golem-notify.sh's line-85 case, never line 84. Pins it distinctly so a
# dropped/reordered/typo'd arm 2 (which would fall through to the gate default
# and falsely report a golem as BLOCKED) fails here. (#251)
test_classifier_idle_no_your() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude is waiting for input"}' "idle" \
        "waiting-for-input (no \"your\") → arm 2"
}

test_classifier_escalation() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"ESCALATION: reuse the state file or a sidecar?"}' \
        "escalation" "ESCALATION: prefix"
}

test_classifier_dead_end() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"DEAD-END: CI still red after ci-fixer exhausted"}' \
        "dead-end" "DEAD-END: prefix"
}

# A RESOLVED:-prefixed message (synthesized by golem-resolve.sh after the
# orchestrator's send-keys plan-approval) classifies as `resolved` — the
# explicit clearing kind that supersedes a stale gate on the next sweep (#422).
test_classifier_resolved() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"RESOLVED: plan gate approved via send-keys"}' \
        "resolved" "RESOLVED: prefix → resolved (#422)"
}

# CRITICAL (#422 pre-PR review): `resolved:` is anchored to the message START, so
# a GENUINE permission gate whose message merely CONTAINS "resolved:" mid-string
# — ordinary command/commit text like `git commit -m '… mark resolved: …'` — must
# stay `gate`, NOT be misclassified as `resolved`. A `resolved` misclassification
# would drop a real pending gate from the BLOCKED set (resolved, like idle, is
# excluded), silently hiding a human decision — the exact failure #422 prevents,
# inverted. `unresolved:` (which contains the substring `resolved:`) is the
# adversarial case an unanchored match would also wrongly catch. This pins the
# prefix anchor: an unanchored `*"resolved:"*` regresses both assertions.
test_classifier_resolved_midmessage_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to run: git commit -m \"fix: mark issue as resolved: closes #99\""}' \
        "gate" "a real gate with mid-message 'resolved:' stays gate, not masked (#422)"
    assert_event '{"message":"Claude needs permission: merge conflicts unresolved: check file.py"}' \
        "gate" "'unresolved:' substring does not mask a real gate (#422)"
}

# A REAPED:-prefixed message (emitted by worktree-rm.sh after teardown) classifies
# as `reaped` — the terminal kind that supersedes a torn-down golem's stale gate on
# the next sweep so it does not ghost on the BLOCKED list (#446).
test_classifier_reaped() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"REAPED: worktree/session for golem-7 torn down"}' \
        "reaped" "REAPED: prefix → reaped (#446)"
}

# CRITICAL (#446, mirrors the #422 resolved-anchoring test): `reaped:` is anchored
# to the message START, so a GENUINE permission gate whose message merely CONTAINS
# "reaped:" mid-string must stay `gate`, NOT be misclassified as `reaped`. A
# `reaped` misclassification would drop a real pending gate from the BLOCKED set
# (reaped, like idle/resolved, is excluded), silently hiding a human decision. This
# pins the prefix anchor: an unanchored `*"reaped:"*` regresses the assertion.
test_classifier_reaped_midmessage_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to run: echo \"files reaped: 3\""}' \
        "gate" "a real gate with mid-message 'reaped:' stays gate, not masked (#446)"
}

test_classifier_gate_default() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    # An unrecognized permission-decision message falls through to the `gate`
    # default (fail loud: surface it rather than silently drop it as idle).
    assert_event '{"message":"Claude needs your permission to run git push"}' \
        "gate" "unrecognized permission message → gate default"
}

# An in-turn AskUserQuestion escalation fork carries NO stable, fork-specific
# signature this hook can key on (issue #321, deferred out of #257/PR #320):
# Claude Code surfaces such a fork via the SDK `canUseTool` callback, not a
# `Notification`, and a plain permission Notification's message is not
# machine-parseable and has no multi-option field. So an AskUserQuestion-style
# permission message MUST stay the fail-loud `gate` default here (only the
# deterministic `ESCALATION:` path is classified as escalation) — a future
# well-meaning heuristic that regressed this would mislabel routine permission
# gates as escalations. This pins that boundary (acceptance criterion 3).
test_classifier_askuserquestion_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to use AskUserQuestion"}' \
        "gate" "AskUserQuestion-style permission message → gate default (#321)"
}

# dead-end must win over escalation when BOTH markers are present (a dead-end IS
# an escalation that also blocks L4), because its case arm precedes escalation's.
test_classifier_dead_end_beats_escalation() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"DEAD-END: ESCALATION: both markers present"}' \
        "dead-end" "dead-end precedence over escalation"
}
