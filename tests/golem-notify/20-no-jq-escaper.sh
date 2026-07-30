# shellcheck shell=bash
# No-jq JSON escaper — golem-notify hook tests (issue #564 split).
#
# Covers the fallback escaper used when jq is absent from PATH.
#
# Sourced by tests/validate-golem-notify.sh, which defines NOTIFY / CONFIG_SH /
# REAL_BASH and sources tests/lib/golem-notify-sandbox.sh for the shared drivers
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# --- No-jq JSON escaper -----------------------------------------------------

# On the jq-less path the escaper is the only thing standing between an
# adversarial GOLEM_ID and a corrupted feed. Feed a GOLEM_ID with an embedded
# double-quote AND backslash; the line must remain valid JSON, with the
# backslash dropped and the quote preserved as string DATA (not a delimiter).
# jq is required here only to VALIDATE the output — the hook itself runs with jq
# stubbed off its PATH.
test_no_jq_escaper_emits_valid_json() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped JSON)"
        return 0
    fi
    local sb golem
    new_sandbox sb
    # GOLEM_ID matches golem-* so it is interpolated verbatim by the encoder.
    run_notify "$sb" '{"message":"unused on the no-jq path"}' 'golem-x"a\b' nojq
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 on the no-jq path"
    assert_valid_json "$NOTIFY_LINE" \
        "the hand-rolled feed line is valid JSON despite a quote+backslash GOLEM_ID"
    golem="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    # Backslash removed, embedded double-quote preserved as data.
    assert_equals 'golem-x"ab' "$golem" \
        "backslash dropped, embedded quote preserved as string data"
}

# The no-jq path still classifies via the message default and always exits 0 (the
# hook must NEVER block the golem). With no jq the message is the literal default,
# which is an unrecognized string → the `gate` default. Assert a valid gate line.
test_no_jq_still_writes_gate_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped JSON)"
        return 0
    fi
    local sb event
    new_sandbox sb
    run_notify "$sb" '{"message":"ignored without jq"}' "golem-9" nojq
    assert_exit 0 "$NOTIFY_RC" "no-jq hook exits 0"
    assert_valid_json "$NOTIFY_LINE" \
        "no-jq feed line is valid JSON"
    event="$(printf '%s' "$NOTIFY_LINE" | jq -r '.event' 2>/dev/null || true)"
    assert_equals "gate" "$event" "no-jq default message classifies as gate"
}
