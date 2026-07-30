# shellcheck shell=bash
# liveness_snapshot — golem-gate-watch tests (issue #564 split).
#
# Covers the mtime heartbeat and its GOLEM_STALL_THRESHOLD env override (#38), plus the tmux-pane (#229/#247) and transcript (#248) wiring tiers that take precedence over it.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh for the shared drivers BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# Liveness (#38): a golem whose activity proxy is INSIDE the stall window is a
# positive heartbeat — "alive (process up ...)", exit 0, never a stall. The
# wording is "process up", not "advancing" (#229): with no live tmux pane the
# sweep falls through to the mtime heartbeat, which proves only that the process
# is up, not that work is happening.
test_liveness_fresh_is_alive() {
    # age 0 (now), generous threshold -> alive.
    _run_liveness_snapshot 1200 0

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a fresh golem"
    assert_contains "$LIVE_OUT" "golem-7" "Fresh golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive" "Fresh golem is reported alive"
    # #229: the mtime heartbeat must NOT be worded "advancing" (reads as progress
    # when it only proves the process is up); it is "process up" instead. The
    # test env has no golem-7 tmux session, so the pane check falls through to
    # this reworded mtime heartbeat.
    assert_contains "$LIVE_OUT" "process up" "Fresh golem heartbeat is worded 'process up', not 'advancing'"
    assert_not_contains "$LIVE_OUT" "advancing" "The misleading 'advancing' wording is gone (#229)"
    local stall_present=0
    case "$LIVE_OUT" in
        *stall*) stall_present=1 ;;
    esac
    assert_equals "0" "$stall_present" "A fresh golem is NOT flagged as a possible stall"
}

# Liveness (#38): a golem whose newest activity is OLDER than the stall window
# is flagged a *possible stall* — still exit 0 (advisory, never a hard-fail).
test_liveness_stale_is_possible_stall() {
    # Activity 3600s ago, threshold 1200s -> stall.
    _run_liveness_snapshot 1200 3600

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 even when flagging a stall"
    assert_contains "$LIVE_OUT" "golem-7" "Stalled golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "possible stall" "Old-activity golem is flagged a possible stall"
}

# Liveness (#38): a golem currently at a FRESH feed gate is reported as gated,
# NOT as a stall — even when its activity proxy is old (a parked golem stops
# touching its worktree). The gate is expected supervision, distinct from a hang.
test_liveness_gated_not_stalled() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (gate detection no-ops without jq)"
        return 0
    fi
    # Old activity (would otherwise be a stall) + a fresh gate for the SAME golem.
    _run_liveness_snapshot 1200 3600 \
        "{\"golem\":\"golem-7\",\"event\":\"gate\",\"message\":\"push gate\",\"ts\":\"$(command date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a gated golem"
    assert_contains "$LIVE_OUT" "gated" "Gated golem is reported gated, not stalled"
    local stall_present=0
    case "$LIVE_OUT" in
        *"possible stall"*) stall_present=1 ;;
    esac
    assert_equals "0" "$stall_present" "A gated golem is NOT double-reported as a stall"
}

# Liveness (#38): env overridability per config.sh precedent. With
# GOLEM_STALL_THRESHOLD lowered BELOW the activity age, the same golem that is
# "alive" under the default flips to "possible stall" — proving the threshold is
# honored from the environment via ${VAR:-default}.
test_liveness_threshold_env_overridable() {
    # Activity 120s ago. Threshold 60s -> stall (120 > 60).
    _run_liveness_snapshot 60 120

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with a low env threshold"
    assert_contains "$LIVE_OUT" "possible stall" \
        "GOLEM_STALL_THRESHOLD is env-overridable (low threshold flips alive->stall)"
}

# --- Liveness pane wiring (#229/#247) ---------------------------------------
# The three tests below drive the tmux-pane branch of liveness_snapshot() END TO
# END via the real `--once-liveness`, with `tmux` stubbed on PATH answering
# has-session + capture-pane. They cover the `case "$pclass"` dispatch added in
# PR #245, its exact emitted strings, and the pane-read-vs-mtime precedence —
# the wiring test_pane_liveness_class (classifier-only, sourced in isolation)
# never reaches. `last activity` is the precedence discriminator: it appears
# ONLY in the mtime-fallback string `alive (process up, last activity … ago)`,
# so its presence/absence proves whether the pane branch or the mtime heartbeat
# produced the line (both share the weaker substring `process up`).

# A scrapeable pane showing the run-spinner classifies `working`: the wiring must
# emit `alive, working` (not the mtime heartbeat). Its absence of `last activity`
# proves the pane read won over the mtime fallback — even though the golem-7
# status file is fresh and would ALSO produce an "alive" mtime line.
test_liveness_pane_working_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "... some output ... ⏵⏵ esc to interrupt"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a working pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive, working" \
        "A run-spinner pane emits the 'alive, working' wiring string, not the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# A scrapeable pane showing the #229 error signature classifies `idle`: the
# wiring must emit the `idle at prompt` warning. Again `last activity` must be
# absent — the pane branch short-circuits before the mtime heartbeat.
test_liveness_pane_idle_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "⏺ Unknown command: /next-issue"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an idle pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "An idle-at-prompt pane (#229 signature) emits the 'idle at prompt' warning"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# A scrapeable pane showing the #446 API-error death signature classifies `died`:
# the liveness wiring must emit the DIED label (with its retriable/terminal class),
# NOT the plain `idle at prompt` — and `last activity` must be absent (the pane
# branch short-circuits before the mtime heartbeat). Pins the `died)` dispatch arm
# in liveness_snapshot() end-to-end (the pull `--once-liveness` surface, distinct
# from the push panes_snapshot path).
test_liveness_pane_died_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "API Error: Request rejected (429)"$'\n'"  ⏵⏵ auto mode on"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a died pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "died — API error: retriable (429)" \
        "A died-on-429 pane emits the DIED label with its class through --once-liveness (#446)"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "A died pane is NOT downgraded to the plain idle-at-prompt liveness wording"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# Precedence: when the pane is scrapeable but classifies indeterminate (empty
# class), the wiring must FALL THROUGH to the mtime heartbeat. With a fresh
# status file that yields `alive (process up, last activity … ago)` — the
# `last activity` wording proves the fallback ran (the pane case emitted nothing
# and did not short-circuit).
test_liveness_pane_indeterminate_falls_through() {
    _run_liveness_snapshot_tmux 1200 0 "just some scrolling build output"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an indeterminate pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "An indeterminate pane falls through to the mtime heartbeat (pane-read -> mtime precedence)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "An indeterminate pane does not fabricate a 'working' verdict"
}

# Own-work-pending pull-channel wiring (#517): a golem parked on its OWN monitors
# paints the bare `⏵⏵ auto mode on` footer (no spinner), which pane_liveness_class
# now classifies "" (indeterminate) via the own-work guard rather than "idle". This
# drives the REAL `--once-liveness` sweep end-to-end (not just the sourced function)
# to prove the guard is wired through liveness_snapshot's dispatch: the sweep must
# fall through to the mtime heartbeat (`last activity`) and NOT emit `idle at
# prompt`. Sibling to test_liveness_pane_indeterminate_falls_through, with an
# own-work footer instead of unrelated build output.
test_liveness_pane_own_work_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "⏺ working"$'\n'"  ⏵⏵ auto mode on · PR #514 · 1 shell, 1 monitor"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an own-work-pending pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "An own-work-pending pane falls through to the mtime heartbeat (#517 pull channel)"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "A golem parked on its own monitors is NOT reported idle on the liveness channel (#517)"
}

# Distinct precedence path from the indeterminate case above: a session that
# EXISTS (has-session succeeds) but whose capture-pane comes back EMPTY. The
# script's own header flags this ("capture-pane is blank until the pane paints")
# — the `[ -n "$pane" ]` guard is false, so pane_liveness_class() is never called
# at all and the sweep falls straight through to the mtime heartbeat. The
# indeterminate test DOES reach the classifier (non-empty pane, empty class); this
# one exercises the guard itself. An empty $pane_text makes the fake tmux
# capture-pane print a lone newline, which command substitution strips to "".
test_liveness_pane_blank_capture_falls_through() {
    _run_liveness_snapshot_tmux 1200 0 ""

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a blank capture-pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "A blank capture-pane (guard false) falls through to the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "A blank capture-pane does not fabricate a 'working' verdict"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "A blank capture-pane does not fabricate an 'idle' verdict"
}

# --- Transcript tier wiring (#248) ------------------------------------------
# The tests below drive the TRANSCRIPT tier of liveness_snapshot() end to end via
# the real `--once-liveness`: no host-visible pane (fake tmux has-session FAILS),
# so the sweep skips the pane branch — exactly the headless golem this tier
# targets — and reads the golem's on-disk transcript instead. They cover the
# `case "$tclass"` dispatch, its emitted strings, and the transcript-vs-mtime
# precedence (the `last activity` wording marks the mtime fallback, absent when
# the transcript tier classifies). All skip when jq is absent — the transcript
# script (and thus the tier) is a no-op without it, exactly like the feed tests.

# A transcript whose last top-level assistant turn is still in flight
# (stop_reason "tool_use") classifies `working`: the wiring emits `alive, working`
# from the transcript, winning over the fresh-status-file mtime heartbeat.
test_liveness_transcript_working_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a working transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive, working" \
        "A turn-in-flight transcript emits the 'alive, working' wiring string"
    assert_contains "$LIVE_OUT" "transcript" \
        "The working line attributes the transcript source"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The transcript read wins over the mtime fallback (no 'last activity' wording)"
}

# A transcript whose last top-level assistant turn has ENDED (stop_reason
# "end_turn") classifies `idle`: the wiring emits the `idle at prompt` warning.
# This is the headless analog of the #229 pane idle signal — the whole point of
# #248. `last activity` must be absent (transcript short-circuits before mtime).
test_liveness_transcript_idle_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an idle transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "A turn-ended transcript emits the 'idle at prompt' warning (headless #229 analog)"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The transcript read wins over the mtime fallback (no 'last activity' wording)"
}

# The errored subclass: the last top-level assistant record carries
# isApiErrorMessage. The wiring emits an idle-at-prompt warning that names the
# error ("errored and idle") — the literal #229 first-command-failure case, now
# caught for a headless golem.
test_liveness_transcript_errored_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: 429"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an errored transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "An errored transcript still surfaces as idle at prompt"
    assert_contains "$LIVE_OUT" "errored and idle" \
        "The errored subclass is named distinctly in the liveness line"
}

# A sub-workflow (isSidechain true) churning tool_use records must NOT mask a
# top-level idle: the classifier keys off top-level records only, so a golem whose
# background review harness is active while the TOP level ended still reads idle.
# Guards the isSidechain filter through the full wiring, not just the unit script.
test_liveness_transcript_sidechain_not_masking() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}' \
            '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}')"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with sidechain churn"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "A top-level idle is not masked by an active sub-workflow (isSidechain filter)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "Sidechain tool_use does not fabricate a top-level 'working' verdict"
}

# Precedence / fall-through: with NO transcript planted (empty body), the
# transcript tier exits non-zero (no transcript dir) and the sweep falls through
# to the mtime heartbeat — the `last activity` wording proves the fallback ran.
# This is the Mode-3-container / no-host-transcript path.
test_liveness_transcript_missing_falls_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 ""

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with no transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "A missing transcript falls through to the mtime heartbeat (transcript -> mtime precedence)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "A missing transcript does not fabricate a 'working' verdict"
}

# An indeterminate transcript (records present but no top-level assistant turn and
# no command error) must also fall through to the mtime heartbeat, not fabricate a
# verdict — the script exits 2 (indeterminate) and the caller falls back.
test_liveness_transcript_indeterminate_falls_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"user","message":{"role":"user","content":"hi"}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an indeterminate transcript"
    assert_contains "$LIVE_OUT" "last activity" \
        "An indeterminate transcript falls through to the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "An indeterminate transcript does not fabricate an idle verdict"
}
