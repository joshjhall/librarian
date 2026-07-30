# shellcheck shell=bash
# liveness stream dedup (#489) — golem-gate-watch tests (issue #564 split).
#
# Covers emit_transitions priming and re-gate dedup, liveness_stabilize, the summary cadence gate, and the heartbeat-interval coercion.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh for the shared drivers BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# --- Liveness stream dedup (#489) -------------------------------------------
# The --stream-liveness heartbeat used to re-emit every golem's line every poll,
# unconditionally, flooding live context. #489 routes it through liveness_stabilize
# -> emit_transitions (the gate channels' dedup) plus a slow aggregate summary. The
# four tests below cover the pure functions in isolation (never the infinite
# --stream-liveness loop — the setsid-free liveness-testing discipline).

# liveness_stabilize: the two mtime-heartbeat lines carry a volatile _fmt_age that
# ticks every poll and would defeat emit_transitions' per-golem message dedup.
# Stabilize drops the age to a stable class, so the SAME golem at the SAME class
# with a DIFFERENT age produces a byte-identical line. Every other liveness line
# (working / idle / died / gated) is already age-free and passes through verbatim.
test_liveness_stabilize_strips_age() {
    local out1 out2
    out1="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 3m ago)\n')"
    )"
    out2="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 12m ago)\n')"
    )"
    assert_equals "$out1" "$out2" \
        "Two different mtime ages stabilize to an identical line (the dedup key)"
    assert_contains "$out1" "golem-7"$'\t'"alive (process up)" \
        "The mtime heartbeat is canonicalized to the age-free class"
    assert_not_contains "$out1" "last activity" \
        "The volatile age substring is stripped"

    # The 'possible stall' mtime line strips its age too.
    local stall
    stall="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\tpossible stall — no progress for 40m\n')"
    )"
    assert_contains "$stall" "golem-7"$'\t'"possible stall" "Stall line is canonicalized to age-free class"
    assert_not_contains "$stall" "40m" "The stall age is stripped"

    # A non-mtime line (already age-free) passes through unchanged.
    local passthru
    passthru="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive, working (esc-to-interrupt active)\n')"
    )"
    assert_contains "$passthru" "golem-7"$'\t'"alive, working (esc-to-interrupt active)" \
        "An already-stable working line passes through verbatim"
}

# The transition-only contract the issue asks for (AC1, AC2, AC4): drive the real
# chained liveness_stabilize -> emit_transitions across ticks, exactly as the
# --stream-liveness arm wires it. One subshell because LAST_EMIT is module state.
#   1. prime (silent)
#   2. same class, DIFFERENT age -> suppressed (AC1: steady state emits nothing)
#   3. alive -> possible stall -> emits (AC2: a transition surfaces promptly)
#   4. -> alive, working -> emits (another class change)
#   5. -> idle at prompt -> emits (AC2 names working→idle explicitly)
#   6. -> gated -> emits (AC2 names →gated explicitly)
#   7. steady on gated -> suppressed
test_liveness_stream_dedup() {
    local out
    out="$(
        source "$GATE_WATCH"
        # 1. Prime a fresh, alive golem -> no output.
        command printf '[prime]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 1m ago)\n')")" 1
        # 2. Same class, the age has ticked on -> stabilized identical -> suppressed.
        command printf '[steady]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 9m ago)\n')")" 0
        # 3. Class flips to a stall -> emits.
        command printf '[stall]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tpossible stall — no progress for 40m\n')")" 0
        # 4. Class flips to working -> emits.
        command printf '[working]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive, working (esc-to-interrupt active)\n')")" 0
        # 5. working -> idle at prompt -> emits (AC2 names this transition).
        command printf '[idle]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\t⚠ idle at prompt — process up, not advancing (check pane)\n')")" 0
        # 6. -> gated -> emits (AC2 names →gated).
        command printf '[gated]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tgated — awaiting decision (not a stall)\n')")" 0
        # 7. Steady on gated -> suppressed.
        command printf '[steady2]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tgated — awaiting decision (not a stall)\n')")" 0
    )"
    # AC1: prime + both steady ticks emit nothing between their markers.
    assert_contains "$out" "[prime][steady][stall]" \
        "Steady state (same class, different age) emits nothing (#489 AC1)"
    assert_contains "$out" "[stall]golem-7"$'\t'"possible stall" \
        "A class change to possible stall emits promptly (#489 AC2)"
    assert_contains "$out" "[working]golem-7"$'\t'"alive, working (esc-to-interrupt active)" \
        "A class change to working emits"
    # AC2 names working→idle and →gated explicitly — each must surface promptly.
    assert_contains "$out" "[idle]golem-7"$'\t'"⚠ idle at prompt" \
        "A working→idle transition emits promptly (#489 AC2)"
    assert_contains "$out" "[gated]golem-7"$'\t'"gated — awaiting decision (not a stall)" \
        "A →gated transition emits promptly (#489 AC2)"
    # emit_transitions prints a trailing newline after each emitted line, so a
    # suppressed [steady2] tick leaves the gated line immediately followed by
    # newline + the [steady2] marker (nothing emitted between them).
    assert_contains "$out" "gated — awaiting decision (not a stall)"$'\n'"[steady2]" \
        "A steady gated class is suppressed on the next tick (no re-emit)"
}

# liveness_summary: the slow aggregate line that keeps the deduped stream from
# looking dead. Counts each class over a mixed snapshot; 'alive, working' and the
# mtime 'process up' heartbeat both count as alive. Empty snapshot -> no output.
test_liveness_summary_counts() {
    local out
    out="$(
        source "$GATE_WATCH"
        liveness_summary "$(command printf '%s\n' \
            'golem-1'$'\t''alive, working (esc-to-interrupt active)' \
            'golem-2'$'\t''alive (process up, last activity 2m ago)' \
            'golem-3'$'\t''⚠ idle at prompt — process up, not advancing (check pane)' \
            'golem-4'$'\t''possible stall — no progress for 40m' \
            'golem-5'$'\t''gated — awaiting decision (not a stall)' \
            'golem-6'$'\t''⚠ died — API error: terminal (401) (check pane)')"
    )"
    assert_contains "$out" "liveness-summary" "Summary line carries the aggregate id"
    assert_contains "$out" "2 alive, 1 idle, 1 stalled, 1 gated, 1 died (6 golems)" \
        "Class counts aggregate correctly (working+process-up both count as alive)"

    local empty
    empty="$(
        source "$GATE_WATCH"
        liveness_summary ""
    )"
    assert_output_empty "$empty" "An empty snapshot produces no summary line"
}

# summary_due: the cadence gate. Due at/above the interval; not due below; a 0 or
# non-numeric interval disables the summary (never crashes the watch on garbage
# GOLEM_LIVENESS_SUMMARY_INTERVAL).
test_summary_due() {
    # Two-arg calls via a sourced subshell; map exit status to 0(due)/1(not due).
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_due 900 900 && echo 0 || echo 1
    )" \
        "Due when elapsed == interval"
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_due 1200 900 && echo 0 || echo 1
    )" \
        "Due when elapsed > interval"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 300 900 && echo 0 || echo 1
    )" \
        "Not due when elapsed < interval"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 5000 0 && echo 0 || echo 1
    )" \
        "Interval 0 disables the summary (never due)"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 5000 abc && echo 0 || echo 1
    )" \
        "Non-numeric interval never crashes / is never due"
}

# summary_enabled (#489 review): gates even the ONE-TIME startup summary so
# "0 disables it" holds literally. Enabled for a positive numeric interval;
# disabled for 0, empty, or non-numeric.
test_summary_enabled() {
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_enabled 900 && echo 0 || echo 1
    )" \
        "A positive interval enables the summary (startup line fires)"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled 0 && echo 0 || echo 1
    )" \
        "Interval 0 disables the summary entirely, incl. the startup line"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled "" && echo 0 || echo 1
    )" \
        "Empty interval disables the summary"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled 15m && echo 0 || echo 1
    )" \
        "Non-numeric interval disables the summary (never crashes)"
}

# GOLEM_LIVENESS_SUMMARY_INTERVAL env-overridability (#489 review), mirroring
# test_liveness_threshold_env_overridable / test_pane_footer_lines_env_overridable:
# set the env var before sourcing and confirm it reaches the summary_interval
# tunable, catching a typo'd var name or broken `${VAR:-default}` wiring. The
# script assigns `summary_interval` at top level whether sourced or executed.
test_summary_interval_env_overridable() {
    # summary_interval is assigned at the sourced script's top level; shellcheck
    # cannot see across the `source`, so silence its not-assigned warning.
    # shellcheck disable=SC2154
    # Unset -> default 900.
    assert_equals "900" "$(
        unset GOLEM_LIVENESS_SUMMARY_INTERVAL
        source "$GATE_WATCH"
        command printf '%s' "$summary_interval"
    )" \
        "summary_interval defaults to 900 when the env var is unset"
    # Set -> honored. `export` so the sourced script reads it from the environment
    # (and so shellcheck sees the assignment as consumed, not dead — SC2034).
    assert_equals "120" "$(
        export GOLEM_LIVENESS_SUMMARY_INTERVAL=120
        source "$GATE_WATCH"
        command printf '%s' "$summary_interval"
    )" \
        "GOLEM_LIVENESS_SUMMARY_INTERVAL is env-overridable (reaches summary_interval)"
}

# heartbeat_interval numeric coercion (#489 review): a non-numeric
# GOLEM_HEARTBEAT_INTERVAL (a plausible typo like "15m") would abort the whole
# --stream-liveness watch on the `$((since_summary + heartbeat_interval))`
# arithmetic under `set -u`. The top-level guard coerces it back to 60 so the
# watch survives; a valid numeric value is honored unchanged.
test_heartbeat_interval_numeric_coercion() {
    # heartbeat_interval is assigned at the sourced script's top level (across the
    # `source` shellcheck cannot follow), so silence the not-assigned warning.
    # shellcheck disable=SC2154
    assert_equals "60" "$(
        export GOLEM_HEARTBEAT_INTERVAL=15m
        source "$GATE_WATCH"
        command printf '%s' "$heartbeat_interval"
    )" \
        "A non-numeric GOLEM_HEARTBEAT_INTERVAL is coerced to 60 (no watch crash)"
    assert_equals "30" "$(
        export GOLEM_HEARTBEAT_INTERVAL=30
        source "$GATE_WATCH"
        command printf '%s' "$heartbeat_interval"
    )" \
        "A valid numeric GOLEM_HEARTBEAT_INTERVAL is honored unchanged"
    # The arithmetic that would crash must be safe now: exercise it directly.
    assert_equals "60" "$(
        export GOLEM_HEARTBEAT_INTERVAL=notanumber
        source "$GATE_WATCH"
        since=0
        since=$((since + heartbeat_interval))
        command printf '%s' "$since"
    )" \
        "The cadence arithmetic no longer aborts under set -u on garbage input"
}

# Ghost filter (#446, Bug #2 Layer B): a golem torn down WITHOUT worktree-rm.sh
# leaves its `gate` line as its most-recent feed entry with no `reaped` line to
# supersede it — so feed_snapshot_live cross-checks golem_has_live_trace and drops
# a gated golem with NO on-disk/tmux trace left (no session, no worktree dir, no
# cache file). A golem WITH a cache-file trace (a live headless/container golem)
# is kept — its gate is real. The shared _run_once_snapshot helper stamps a cache
# trace per feed golem, so here we craft the ghost by hand: run `--once` directly
# against a repo where golem-1 has a feed gate but NO trace, and golem-2 has both.
test_ghost_gate_dropped_when_no_trace() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi
    local tmp
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN
    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    local ts
    ts="$(command date -u +%FT%TZ)"
    {
        command printf '{"ts":"%s","golem":"golem-1","event":"gate","message":"needs permission"}\n' "$ts"
        command printf '{"ts":"%s","golem":"golem-2","event":"gate","message":"needs permission"}\n' "$ts"
    } >"$tmp/.worktrees/.status/feed.jsonl"
    # Only golem-2 gets a cache-file trace; golem-1 is a ghost (torn down, no trace).
    command printf '{"golem":"golem-2","issue":2}\n' >"$tmp/.worktrees/.status/golem-2.json"

    # A fake tmux whose `ls`/`has-session` report NO sessions, so a real host golem
    # cannot leak a trace in (mirrors the #436 hermetic-tmux guard elsewhere).
    local stub_bin real_bash real_jq real_git
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    command ln -s "$real_bash" "$stub_bin/bash"
    real_git="$(command -v git)"
    command ln -s "$real_git" "$stub_bin/git"
    real_jq="$(command -v jq || true)"
    [ -n "$real_jq" ] && command ln -s "$real_jq" "$stub_bin/jq"
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    has-session) exit 1 ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    # Two more gated golems exercise the OTHER two KEEP probes of
    # golem_has_live_trace: golem-3 kept via an `issue-N.json` cache alias,
    # golem-4 kept via an on-disk worktree dir (no cache file of its own).
    {
        command printf '{"ts":"%s","golem":"golem-3","event":"gate","message":"needs permission"}\n' "$ts"
        command printf '{"ts":"%s","golem":"golem-4","event":"gate","message":"needs permission"}\n' "$ts"
    } >>"$tmp/.worktrees/.status/feed.jsonl"
    command printf '{"golem":"golem-3","issue":3}\n' >"$tmp/.worktrees/.status/issue-3.json"
    command mkdir -p "$tmp/.worktrees/issue-4"

    local out rc=0
    out="$(
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                GOLEM_BLOCK_TTL=999999999999 GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once 2>/dev/null
    )" || rc=$?
    assert_equals "0" "$rc" "Ghost-filtered --once still exits 0"
    assert_not_contains "$out" "golem-1" \
        "A gated golem with no live trace (ghost) is dropped from BLOCKED (#446)"
    assert_contains "$out" "golem-2" \
        "A gated golem with a golem-N.json cache-file trace is kept (its gate is real)"
    assert_contains "$out" "golem-3" \
        "A gated golem kept via an issue-N.json cache alias trace is not dropped"
    assert_contains "$out" "golem-4" \
        "A gated golem kept via an on-disk worktree dir trace is not dropped"
}

# API-error death matcher (#446, Bug #4): pane_is_api_error matches the Claude Code
# `API Error <4xx/5xx>` signature in the wider scrollback window, while an ACTIVE
# run-spinner in the footer vetoes it (a working golem reading an old error is not
# dead), and prose mentioning "api error" without a code does not match. The
# classifier splits retriable (429/5xx) from terminal (auth/quota 4xx).
test_pane_is_api_error() {
    local died term_pane working prose
    died=$'work output\nAPI Error: Request rejected (429)\n\n  Try again\n⏵⏵ auto mode on'
    term_pane=$'API Error: 403 Forbidden\n\n⏵⏵ auto mode on'
    working=$'API Error: Request rejected (429)\n· Doing work (esc to interrupt)'
    prose=$'we discussed an api error earlier\n\n⏵⏵ auto mode on'

    assert_equals "0" "$(_pane_rc pane_is_api_error "$died")" \
        "A 429 API-error scrollback with a bare footer matches (died)"
    assert_equals "0" "$(_pane_rc pane_is_api_error "$term_pane")" \
        "A 403 API-error scrollback matches (terminal death)"
    assert_equals "1" "$(_pane_rc pane_is_api_error "$working")" \
        "The same error WITH an active run-spinner is NOT a death (spinner vetoes)"
    assert_equals "1" "$(_pane_rc pane_is_api_error "$prose")" \
        "Prose mentioning 'api error' without a status code is NOT a death"

    # A 5xx (overloaded/server) is transient too — the `5??` glob arm, distinct
    # from the literal 429. Pins that a 529/500 is retriable, not terminal.
    local overloaded
    overloaded=$'API Error: 529 Overloaded\n\n⏵⏵ auto mode on'
    assert_equals "0" "$(_pane_rc pane_is_api_error "$overloaded")" \
        "A 529 API-error scrollback matches (transient overload death)"

    # Classification: retriable (429 + 5xx) vs terminal (other 4xx).
    local rc_class fivexx_class term_class
    rc_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$died"
    )"
    fivexx_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$overloaded"
    )"
    term_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$term_pane"
    )"
    assert_equals "retriable (429)" "$rc_class" "429 classifies as retriable"
    assert_equals "retriable (529)" "$fivexx_class" "a 5xx code classifies as retriable (the 5?? arm, not just 429)"
    assert_equals "terminal (403)" "$term_class" "403 classifies as terminal"
}

# End-to-end death dispatch (#446, Bug #4): drive the REAL panes_snapshot() via
# `--once-panes` to pin that a died-on-API-error pane emits the DIED label with its
# retriable/terminal class, AND that the death read is dispatched BEFORE
# pane_is_turn_end — a died pane also paints the bare `auto mode on` footer, so the
# more-specific death must win, never downgraded to turn-end.
test_panes_snapshot_died_dispatch() {
    _run_panes_snapshot_tmux "API Error: Request rejected (429)"$'\n'"⏺ stopped"$'\n'"  ⏵⏵ auto mode on"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a died pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ died — API error: retriable (429) (check pane)" \
        "A died-on-429 pane emits the DIED label with a retriable class end-to-end"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A died pane is NOT downgraded to turn-end/idle (death wins)"

    # A terminal (auth) death classifies distinctly.
    _run_panes_snapshot_tmux "API Error: 401 Unauthorized"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ died — API error: terminal (401) (check pane)" \
        "A died-on-401 pane emits the DIED label with a terminal class"

    # A plan-gate + a stale error in scrollback: the modal gate still wins (death
    # is dispatched after the three modal matchers, before turn-end only).
    _run_panes_snapshot_tmux "API Error: 429"$'\n'"1. Yes, and use auto mode"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan overlay wins over a scrollback error (modal gates precede the death read)"
    assert_not_contains "$PANES_OUT" "died — API error" \
        "A plan+error pane is NOT labelled a death (modal wins)"
}

# GOLEM_PANE_FOOTER_LINES env-override (#458, mirroring
# test_liveness_threshold_env_overridable for GOLEM_STALL_THRESHOLD): every pane
# matcher #458 names scopes its match to the last $pane_footer_lines lines, where
# `pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"` is read once at source time.
# No prior test set the env var to a non-default value, so a regression that
# silently ignored it (typo'd var name, value never reaching the sourced context)
# would go uncaught. This pins the ${VAR:-default} wiring in BOTH directions
# (shrink hides an in-default-window trigger; enlarge reveals an
# out-of-default-window one) across ALL SIX footer-keyed matchers — the five named
# in #458 (pane_is_gate, pane_is_fork, pane_is_plan_gate, pane_is_turn_end,
# pane_liveness_class) plus pane_pending_own_work (#517) — so a per-matcher
# hardcoded 8 (not reading the shared var) is caught in any one of them, not just a
# single wiring point. _pane_rc sources
# the script in a subshell, so the GOLEM_PANE_FOOTER_LINES= prefix reaches that
# source-time read. (pane_is_api_error, added in #446, keys its PRIMARY match off
# $pane_error_lines and uses $pane_footer_lines only for its spinner-veto guard,
# so it is out of #458's footer-window scope.)
test_pane_footer_lines_env_overridable() {
    local four nine

    # Shrink direction: a trigger 5 lines from the bottom is INSIDE the default
    # 8-line window (match) but OUTSIDE a shrunk 3-line window (no match).
    # Flipping match->no-match as the window shrinks proves the smaller value
    # took effect. Exercised on the two rc-returning gate matchers.
    four=$'f1\nf2\nf3\nf4'
    assert_equals "0" "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$four")" \
        "pane_is_gate: a gate 5 lines up matches under the default 8-line window"
    assert_equals "1" \
        "$(GOLEM_PANE_FOOTER_LINES=3 _pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$four")" \
        "pane_is_gate: GOLEM_PANE_FOOTER_LINES=3 shrinks the window so the same gate falls outside it"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$four")" \
        "pane_is_plan_gate: a plan overlay 5 lines up matches under the default 8-line window"
    assert_equals "1" \
        "$(GOLEM_PANE_FOOTER_LINES=3 _pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$four")" \
        "pane_is_plan_gate: GOLEM_PANE_FOOTER_LINES=3 shrinks the window so the same plan overlay falls outside it"

    # Enlarge direction: a trigger 10 lines from the bottom is OUTSIDE the
    # default 8-line window (no match) but INSIDE an enlarged 12-line window
    # (match). Exercised on the remaining rc matchers (fork, turn_end) plus the
    # string-returning classifier (liveness_class emits "" vs "idle").
    nine=$'g1\ng2\ng3\ng4\ng5\ng6\ng7\ng8\ng9'
    assert_equals "1" "$(_pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate"$'\n'"$nine")" \
        "pane_is_fork: a fork footer 10 lines up falls outside the default 8-line window"
    assert_equals "0" \
        "$(GOLEM_PANE_FOOTER_LINES=12 _pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate"$'\n'"$nine")" \
        "pane_is_fork: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same fork falls inside it"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on"$'\n'"$nine")" \
        "pane_is_turn_end: an idle footer 10 lines up falls outside the default 8-line window"
    assert_equals "0" \
        "$(GOLEM_PANE_FOOTER_LINES=12 _pane_rc pane_is_turn_end "  ⏵⏵ auto mode on"$'\n'"$nine")" \
        "pane_is_turn_end: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same idle footer falls inside it"
    # pane_pending_own_work (#517) reads the same shared $pane_footer_lines, so a
    # per-matcher hardcoded 8 would go uncaught without exercising it here too. An
    # own-work token 10 lines up is outside the default window (no match) but inside
    # the enlarged 12-line one (match).
    assert_equals "1" "$(_pane_rc pane_pending_own_work "· 1 monitor"$'\n'"$nine")" \
        "pane_pending_own_work: an own-work token 10 lines up falls outside the default 8-line window"
    assert_equals "0" \
        "$(GOLEM_PANE_FOOTER_LINES=12 _pane_rc pane_pending_own_work "· 1 monitor"$'\n'"$nine")" \
        "pane_pending_own_work: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same token falls inside it"

    # pane_liveness_class returns a CLASS STRING, not an rc — capture stdout via a
    # sourced subshell. The env var is set BEFORE `source` (as _pane_rc does it)
    # so the source-time `pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"` read
    # picks it up — NOT assigned to pane_footer_lines directly, which would bypass
    # the very ${VAR:-default} wiring under test. Same enlarge direction: the idle
    # footer 10 lines up is unclassified ("") under the default window, "idle"
    # once the enlarged window covers it.
    assert_equals "" \
        "$( (
            source "$GATE_WATCH"
            pane_liveness_class "  ⏵⏵ auto mode on"$'\n'"$nine"
        ) 2>/dev/null)" \
        "pane_liveness_class: an idle footer 10 lines up is unclassified under the default 8-line window"
    assert_equals "idle" \
        "$( (
            export GOLEM_PANE_FOOTER_LINES=12
            source "$GATE_WATCH"
            pane_liveness_class "  ⏵⏵ auto mode on"$'\n'"$nine"
        ) 2>/dev/null)" \
        "pane_liveness_class: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same idle footer classifies idle"
}
