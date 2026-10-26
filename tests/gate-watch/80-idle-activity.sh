# shellcheck shell=bash
# Busy golem reported idle (#1203) — golem-gate-watch tests (issue #564 split).
#
# A 4-golem orchestrate run produced dozens of false `⚠ idle at prompt` alerts:
# golems that had ended their turn while a background push / CI poll / review
# harness ran on. Two fixes are pinned here:
#   1. OWN_WORK_RE learns the BARE background-shell count (`· N shell(s)`), which
#      it used to accept only when a monitor count followed it. Every footer the
#      issue recorded verbatim is a row below.
#   2. No idle line while the golem visibly progresses: its transcript or git
#      index moved within GOLEM_IDLE_ACTIVITY_WINDOW. That covers the whole
#      footer-redesign class rather than one more arm — and the control cases
#      prove a genuinely idle golem (nothing running, nothing moving) still
#      alerts, so the gate is not a blanket mute.
#
# Own file rather than 30-helpers-and-modes.sh, which is at its shell budget.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh first.

# A footer with no work chrome at all: the shape the activity gate exists for.
_ACT_PANE="⏺ done"$'\n'"  ⏵⏵ auto mode on · ← for agents"

# AC1 — every footer in the issue's table, verbatim. The first four were read
# as IDLE before this change; the last two were already busy and must stay so.
test_idle_activity_issue_footers_are_own_work() {
    local row
    for row in \
        "✻ Baked for 2m · done 1:06 AM · 1 shell still running" \
        "⏵⏵ auto mode on · 1 shell · ← for agents · ↓ to manage" \
        "⏵⏵ auto mode on · 3 shells · ← for agents" \
        "✻ Cooked for 9s · 2 shells still running" \
        "⏵⏵ auto mode on · 1 shell, 2 monitors · ←" \
        "◯ next-issue-review  ▰▰▰▰▱▱▱  4/6 · 11s"; do
        assert_equals "0" "$(_pane_rc pane_pending_own_work "$row")" \
            "Own work pending: $row"
        assert_equals "1" "$(_pane_rc pane_is_turn_end "$row"$'\n'"  ⏵⏵ auto mode on")" \
            "Not idle at prompt: $row"
    done
}

# The bare-shell arm is anchored on the `·` footer bullet, like the monitor arm
# (#517 cycle-3): prose that merely mentions shells must NOT suppress a real idle.
test_idle_activity_shell_arm_is_anchored() {
    local prose
    for prose in \
        "ran 3 shell scripts against the fixture" \
        "Opened 1 shell, then exited" \
        "PR #514 · 12 shellfish recipes" \
        "  ⏵⏵ auto mode on · ← for agents"; do
        assert_equals "1" "$(_pane_rc pane_pending_own_work "$prose")" \
            "Not own work: $prose"
    done
    assert_equals "0" "$(_pane_rc pane_is_turn_end "ran 3 shell scripts"$'\n'"  ⏵⏵ auto mode on")" \
        "Shell prose above an idle footer still reads idle"
}

# AC2 — the push channel. A golem whose transcript was written seconds ago is
# not pushed as idle, whatever its footer shows (index aged out, so the
# transcript alone decides).
test_idle_activity_fresh_transcript_suppresses_push() {
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_TRANSCRIPT_AGE=5 REG_INDEX_AGE=600 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_equals "0" "$REG_RC" "--once-panes exits 0"
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "A transcript written 5s ago suppresses the idle push (#1203)"
}

# The git index is the second signal — a golem committing without a host-visible
# transcript (container) is not idle either.
test_idle_activity_fresh_index_suppresses_push() {
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_INDEX_AGE=5 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "An index touched 5s ago (via the worktree's gitdir pointer) suppresses the idle push"
}

# git writes the pointer absolute, so the relative `gitdir:` branch needs its own
# case: resolved against the wrong base it finds no index, fails open, and the
# fresh-index golem would alert. The aged control proves the pointer is what is read.
test_idle_activity_relative_gitdir_index() {
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_INDEX_AGE=5 REG_GITDIR_RELATIVE=1 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "A fresh index behind a RELATIVE gitdir pointer suppresses the idle push"
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_INDEX_AGE=600 REG_GITDIR_RELATIVE=1 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_contains "$REG_OUT" "idle at prompt" \
        "Control: the same relative pointer to an aged index still alerts"
}

# A future-dated mtime (container/host clock skew) has a negative age, which a
# bare `-le window` reads as recent forever — a permanent mute. It must not count.
test_idle_activity_future_mtime_is_not_recent() {
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_TRANSCRIPT_AGE=-600 REG_INDEX_AGE=600 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_contains "$REG_OUT" "golem-9"$'\t'"⚠ idle at prompt" \
        "A transcript dated 10 min in the future does not mute the idle push"
}

# AC4 — no regression. Nothing running, nothing moving: still alerts.
test_idle_activity_stale_golem_still_alerts() {
    GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_TRANSCRIPT_AGE=600 REG_INDEX_AGE=600 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_contains "$REG_OUT" "golem-9"$'\t'"⚠ idle at prompt" \
        "A golem idle past the window still raises the idle push"
}

# The gate fails OPEN: disabled (0) or a malformed knob keeps today's alert.
test_idle_activity_window_off_or_malformed_alerts() {
    local w
    for w in 0 2m; do
        GOLEM_IDLE_ACTIVITY_WINDOW="$w" REG_TRANSCRIPT_AGE=5 \
            _run_panes_registry "$_ACT_PANE" ""
        assert_contains "$REG_OUT" "idle at prompt" \
            "GOLEM_IDLE_ACTIVITY_WINDOW=$w never mutes the alert (fail open)"
    done
}

# The liveness PULL channel reads the same gate at its pane-idle arm, so the two
# channels cannot disagree about one golem.
test_idle_activity_liveness_pane_arm() {
    GW_MODE=--once-liveness GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_TRANSCRIPT_AGE=5 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_contains "$REG_OUT" "golem-9"$'\t'"alive (turn ended, recent activity)" \
        "Liveness renders a recently-active idle-looking pane as alive"
    assert_not_contains "$REG_OUT" "idle at prompt" "No liveness idle line while active"

    GW_MODE=--once-liveness GOLEM_IDLE_ACTIVITY_WINDOW=120 REG_TRANSCRIPT_AGE=600 REG_INDEX_AGE=600 \
        _run_panes_registry "$_ACT_PANE" ""
    assert_contains "$REG_OUT" "idle at prompt" "Control: a stale golem's liveness still reads idle"
}

# The transcript tier (headless golem) — idle and errored both yield to activity.
test_idle_activity_liveness_transcript_arms() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    local ended='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'
    local errored='{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"API Error"}]}}'
    LIVE_TRANSCRIPT_FRESH=1 _run_liveness_snapshot_transcript 1200 0 "$ended"
    assert_contains "$LIVE_OUT" "golem-7"$'\t'"alive (turn ended, recent activity)" \
        "A turn-ended transcript written just now is not idle"
    LIVE_TRANSCRIPT_FRESH=1 _run_liveness_snapshot_transcript 1200 0 "$errored"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "An errored transcript written just now is not idle yet"
    _run_liveness_snapshot_transcript 1200 0 "$errored"
    assert_contains "$LIVE_OUT" "errored and idle" \
        "Control: the same errored transcript, aged, still reads errored-and-idle"
}
