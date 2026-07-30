# shellcheck shell=bash
# helper / mode coverage (#82) — golem-gate-watch tests (issue #564 split).
#
# Covers argument dispatch, _fmt_age, and the pane-overlay matchers (plan gate / permission gate / AskUserQuestion fork / turn-end) with their footer anchoring (#447/#452/#458/#517).
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh for the shared drivers BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# --- Helper / mode coverage (#82) -------------------------------------------
# The tests below exercise the previously-untested surface: the unknown-mode
# error path, the _fmt_age formatter, the two pane-overlay matchers, and the
# emit_transitions dedup logic. The pure functions are reached by SOURCING the
# script (its bottom main-guard means a source defines functions without running
# the drive block) in a subshell, so the script's `set -uo pipefail` never leaks
# into the harness.

# Unknown mode: an unrecognized argument must exit 2 with a usage message naming
# the valid modes — the only non-zero exit the script makes (snapshots always
# exit 0). Run as a SUBPROCESS (not sourced) so the `exit 2` is observed as a
# real exit code.
test_unknown_mode_exits_2() {
    local out rc=0
    out="$(bash "$GATE_WATCH" --bogus-mode 2>&1)" && rc=0 || rc=$?
    assert_equals "2" "$rc" "Unknown mode exits 2"
    assert_contains "$out" "unknown mode" "Usage message names the unknown mode"
    assert_contains "$out" "--once" "Usage message lists the valid modes"
}

# An empty/no argument defaults to --once (mode="--once") and must NOT hit the
# unknown-mode arm — exit 0, and no "unknown mode" complaint.
test_no_arg_defaults_to_once() {
    local out rc=0
    # Run from a tmpdir with no git repo context; --once resolves no feed and
    # exits 0 cleanly (status_dir empty -> the [ -n "$feed" ] guard skips).
    out="$(cd "$(command mktemp -d)" && bash "$GATE_WATCH" 2>&1)" && rc=0 || rc=$?
    assert_equals "0" "$rc" "No argument defaults to --once and exits 0"
    assert_not_contains "$out" "unknown mode" "Default mode does not hit the error path"
}

# _fmt_age: < 60 seconds renders "Ns"; >= 60 renders whole "Nm" (integer minutes,
# truncating). Covers the boundary (59/60), a multi-minute value, and zero.
test_fmt_age_formats() {
    local r
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 0
    ))"
    assert_equals "0s" "$r" "_fmt_age 0 -> 0s"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 59
    ))"
    assert_equals "59s" "$r" "_fmt_age 59 -> 59s (just under the minute)"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 60
    ))"
    assert_equals "1m" "$r" "_fmt_age 60 -> 1m (the boundary)"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 125
    ))"
    assert_equals "2m" "$r" "_fmt_age 125 -> 2m (integer-minute truncation)"
}

# pane_is_plan_gate: each plan-overlay phrase matches (rc 0); unrelated text does
# not (rc 1). The phrases come straight from the matcher's case arms.
test_pane_is_plan_gate() {
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "... Ready to code? ...")" \
        "'Ready to code' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:")" \
        "'Here is Claude's plan' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Would you like to proceed?")" \
        "'Would you like to proceed' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "1. Yes, and use auto mode")" \
        "'Yes, and use auto mode' is a plan gate"
    assert_equals "1" "$(_pane_rc pane_is_plan_gate "just some scrolling build output")" \
        "Unrelated work output is NOT a plan gate"

    # Footer anchoring (#452, mirroring test_pane_is_fork_footer_anchored / the
    # #246 pane_liveness_class fix): the matcher scans only the last GOLEM_PANE_
    # FOOTER_LINES lines (default 8), NOT the whole scrollback. A golem
    # editing/`cat`-ing a file whose text carries a plan phrase — this script's
    # own comments and tests do — must not self-trip a false plan gate. `filler`
    # pushes the scrolled phrase out of the footer window.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_plan_gate "grep 'Here is Claude'\''s plan' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled plan phrase above a working footer does not fake a plan gate"
    assert_equals "0" \
        "$(_pane_rc pane_is_plan_gate "$filler"$'\n'"Here is Claude's plan:")" \
        "A plan phrase inside the footer window still matches"

    # Tail-window boundary (#459): pin the exact inclusive/exclusive edge of the
    # default 8-line footer window, where `tail -n 8 <<<` over a here-string
    # (trailing newline) makes an off-by-one easy to regress silently. Phrase +
    # 7 filler = 8 lines -> phrase sits at the Nth-from-last line, inside the
    # window (rc 0); phrase + 8 filler = 9 lines -> (N+1)th-from-last, outside
    # (rc 1).
    local edge_in edge_out
    edge_in=$'f1\nf2\nf3\nf4\nf5\nf6\nf7'
    edge_out=$'f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8'
    assert_equals "0" \
        "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$edge_in")" \
        "A plan phrase at the Nth-from-last line is inside the footer window"
    assert_equals "1" \
        "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$edge_out")" \
        "A plan phrase at the (N+1)th-from-last line is outside the footer window"
}

# pane_liveness_class (#229): the run-spinner marks "working"; the #229 error
# signature and a bare auto-mode footer mark "idle"; the spinner WINS over the
# footer (a working golem still paints the footer); unrelated text is "".
test_pane_liveness_class() {
    assert_equals "working" "$(_pane_class "... ⏵⏵ esc to interrupt")" \
        "'esc to interrupt' spinner marks the pane working"
    assert_equals "idle" "$(_pane_class "⏺ Unknown command: /next-issue")" \
        "The #229 'Unknown command' failure marks the pane idle"
    assert_equals "idle" "$(_pane_class "❯"$'\n'"  ⏵⏵ auto mode on")" \
        "A bare 'auto mode on' footer (no spinner) marks the pane idle"
    # #517: a golem parked on its OWN monitors paints the same bare auto-mode footer
    # but is alive with a queued next action — the own-work guard makes the pull
    # classifier return "" (indeterminate) so the caller falls through to the mtime
    # heartbeat instead of falsely reporting idle. Mirrors the push-channel fix.
    assert_equals "" "$(_pane_class "⏺ working"$'\n'"  ⏵⏵ auto mode on · 2 monitors")" \
        "A golem parked on its own monitors is indeterminate, NOT idle (#517 pull channel)"
    # Spinner precedence: both the working spinner AND the auto-mode footer on
    # screen must resolve to working, not idle (a working auto-mode golem shows
    # both). Guards the check order in the classifier.
    assert_equals "working" "$(_pane_class "esc to interrupt"$'\n'"  ⏵⏵ auto mode on")" \
        "The spinner wins over the auto-mode footer -> working"
    assert_equals "" "$(_pane_class "just some scrolling build output")" \
        "Unrelated pane text is indeterminate (empty class)"
    # #446 death read: an API-error scrollback with a bare footer classifies as
    # `died` (checked before the plain idle arms so it is not masked as idle); the
    # same error under an active spinner is `working` (spinner wins).
    assert_equals "died" "$(_pane_class "API Error: Request rejected (429)"$'\n'"  ⏵⏵ auto mode on")" \
        "An API-error scrollback with no spinner classifies as died, not idle (#446)"
    assert_equals "working" "$(_pane_class "API Error: 429"$'\n'"  ⏵⏵ esc to interrupt")" \
        "The same API-error under an active spinner is working (spinner wins over death)"

    # Footer anchoring (#246): the match is scoped to the last GOLEM_PANE_FOOTER_
    # LINES lines (default 8), NOT the whole scrollback. A golem cat-ing/grepping
    # a file whose text carries a trigger phrase (this very script does) must not
    # self-trip the classifier. `filler` pushes the scrolled phrase out of the
    # footer window.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    # (a) Fail-loud collision: `esc to interrupt` in SCROLLBACK above a real idle
    # footer -> idle (not a false working). The spinner phrase is > 8 lines up.
    assert_equals "idle" \
        "$(_pane_class "grep esc to interrupt golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ auto mode on")" \
        "A scrolled 'esc to interrupt' above an idle footer does not fake 'working'"
    # (b) Fail-open collision: `auto mode on` / `Unknown command` in SCROLLBACK
    # above a real run-spinner footer -> working (not a false idle that would
    # suppress #229 detection).
    assert_equals "working" \
        "$(_pane_class "cat golem-launch.sh # auto mode on / Unknown command"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "Scrolled idle phrases above a live spinner do not fake 'idle'"
    # (c) The idle footer requires its `⏵⏵` chrome glyph: a bare-words 'auto mode
    # on' line with no glyph, even inside the footer window, stays indeterminate.
    assert_equals "" "$(_pane_class "the docs mention auto mode on here")" \
        "A bare-words 'auto mode on' with no chrome glyph is indeterminate"
}

# pane_is_gate: the generic permission-decision overlay matches (rc 0); other
# text does not (rc 1). Distinct from the plan-gate matcher.
test_pane_is_gate() {
    assert_equals "0" "$(_pane_rc pane_is_gate "Do you want to proceed?")" \
        "'Do you want to proceed' is a permission gate"
    assert_equals "1" "$(_pane_rc pane_is_gate "Here is Claude's plan:")" \
        "A plan overlay is NOT matched by the generic-gate matcher"
    assert_equals "1" "$(_pane_rc pane_is_gate "nothing to see")" \
        "Unrelated text is NOT a permission gate"

    # Footer anchoring (#452): scoped to the last GOLEM_PANE_FOOTER_LINES lines,
    # NOT the whole scrollback — a golem editing/`cat`-ing a file that mentions
    # `Do you want to proceed` must not self-trip a false permission gate.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_gate "echo 'Do you want to proceed' >> fixtures.txt"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled 'Do you want to proceed' above a working footer does not fake a gate"
    assert_equals "0" \
        "$(_pane_rc pane_is_gate "$filler"$'\n'"Do you want to proceed?")" \
        "A 'Do you want to proceed' inside the footer window still matches"

    # Tail-window boundary (#459): pin the exact inclusive/exclusive edge of the
    # default 8-line footer window (see test_pane_is_plan_gate for the rationale).
    # Phrase + 7 filler = 8 lines -> Nth-from-last, inside (rc 0); phrase + 8
    # filler = 9 lines -> (N+1)th-from-last, outside (rc 1).
    local edge_in edge_out
    edge_in=$'f1\nf2\nf3\nf4\nf5\nf6\nf7'
    edge_out=$'f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8'
    assert_equals "0" \
        "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$edge_in")" \
        "A permission phrase at the Nth-from-last line is inside the footer window"
    assert_equals "1" \
        "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$edge_out")" \
        "A permission phrase at the (N+1)th-from-last line is outside the footer window"
}

# pane_is_fork (#257): the AskUserQuestion escalation-fork overlay matches on its
# `Enter to select` footer (rc 0); a plan overlay, the generic-gate phrase, and
# unrelated work output do NOT (rc 1). This is the whole gate category the pane
# channel silently dropped before #257.
test_pane_is_fork() {
    assert_equals "0" "$(_pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate · Esc to cancel")" \
        "The 'Enter to select' fork footer is an escalation fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "Do you want to proceed?")" \
        "A generic permission gate footer alone is NOT a fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "Here is Claude's plan:")" \
        "A plan overlay is NOT a fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "just some scrolling build output")" \
        "Unrelated work output is NOT a fork"
}

# Footer anchoring (#257, mirroring the #246 pane_liveness_class fix): pane_is_fork
# scans only the last GOLEM_PANE_FOOTER_LINES lines, NOT the whole scrollback. A
# golem cat-ing/grepping a file whose text carries `Enter to select` — this very
# test file and golem-gate-watch.sh's own comments do — must not self-trip the
# matcher into a false escalation. `filler` pushes the scrolled phrase out of the
# footer window (default 8 lines).
test_pane_is_fork_footer_anchored() {
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_fork "grep 'Enter to select' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled 'Enter to select' above a non-fork footer does not fake a fork"
    assert_equals "0" \
        "$(_pane_rc pane_is_fork "$filler"$'\n'"Enter to select · ↑/↓ to navigate")" \
        "An 'Enter to select' footer inside the window still matches"
}

# Precedence (#257): a pane carrying BOTH a plan signature (`Yes, and use auto
# mode`) AND the fork footer (`Enter to select`) must still be a plan gate —
# panes_snapshot checks pane_is_plan_gate FIRST, so a real plan overlay is never
# downgraded to a fork. Pins that branch order at the matcher level. (The
# end-to-end dispatch order is pinned by test_panes_snapshot_dispatch below.)
test_pane_fork_plan_precedence() {
    local both="1. Yes, and use auto mode"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "$both")" \
        "A plan+fork pane is matched by pane_is_plan_gate (plan gate wins)"
    assert_equals "0" "$(_pane_rc pane_is_fork "$both")" \
        "pane_is_fork also matches it, but panes_snapshot checks plan-gate first"
}

# panes_snapshot dispatch (#257): a fork-only pane emits the escalation label; a
# plan+fork pane still emits the plan label (plan-gate wins); a gate+fork pane
# emits the permission-gate label (generic gate wins over fork). Pins the whole
# if/elif chain and the exact output strings end-to-end.
test_panes_snapshot_dispatch() {
    _run_panes_snapshot_tmux "What scope? "$'\n'"Enter to select · ↑/↓ to navigate · Esc to cancel"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a fork pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "A fork-only pane emits the escalation label end-to-end"

    _run_panes_snapshot_tmux "1. Yes, and use auto mode"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan+fork pane emits the plan-gate label (plan wins over fork)"
    assert_not_contains "$PANES_OUT" "escalation —" \
        "A plan+fork pane is NOT labelled an escalation"

    _run_panes_snapshot_tmux "Do you want to proceed?"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"permission gate — awaiting decision" \
        "A gate+fork pane emits the permission-gate label (generic gate wins over fork)"
    assert_not_contains "$PANES_OUT" "escalation —" \
        "A routine permission gate is NOT downgraded to an escalation"

    # No-match pane: ordinary work output matches none of the four matchers ->
    # panes_snapshot emits NOTHING (no golem line). Pins the silent fall-through
    # end-to-end so an errant unconditional emit branch would be caught. The
    # footer here is a bare-words 'auto mode on' WITHOUT the ⏵⏵ glyph, so it also
    # pins that pane_is_turn_end's glyph guard holds in the dispatch chain.
    _run_panes_snapshot_tmux "just some scrolling build output"$'\n'"auto mode on but no glyph"
    assert_not_contains "$PANES_OUT" "golem-9" \
        "A pane matching no overlay emits no line (silent fall-through)"
}

# pane_is_turn_end (#447): a turn-ended/idle-at-prompt golem paints the bare
# `⏵⏵ auto mode on` footer with NO `esc to interrupt` run-spinner (rc 0). A pane
# still running (spinner present) is NOT idle even with the same footer (rc 1,
# spinner checked first); a bare-words `auto mode on` lacking the ⏵⏵ glyph is NOT
# idle (rc 1); unrelated output is NOT idle (rc 1). Mirrors the `idle` arm of
# pane_liveness_class — this is the stall class the pane push channel dropped
# before #447.
test_pane_is_turn_end() {
    assert_equals "0" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on")" \
        "A '⏵⏵ auto mode on' footer with no spinner is turn-ended/idle"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on · esc to interrupt")" \
        "The same footer WITH the run-spinner is working, not idle (spinner wins)"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "auto mode on")" \
        "A bare-words 'auto mode on' without the ⏵⏵ glyph is NOT turn-ended"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "just some scrolling build output")" \
        "Unrelated work output is NOT turn-ended"
}

# Footer anchoring (#447, mirroring test_pane_is_fork_footer_anchored / the #246
# pane_liveness_class fix): pane_is_turn_end scans only the last
# GOLEM_PANE_FOOTER_LINES lines. This very test file and golem-gate-watch.sh's own
# comments carry `⏵⏵ auto mode on`, so a golem cat-ing/grepping them must not
# self-trip a false idle. `filler` pushes the scrolled footer glyph out of the
# window; the real footer below it (an active spinner) must win.
test_pane_is_turn_end_footer_anchored() {
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "grep '⏵⏵ auto mode on' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled '⏵⏵ auto mode on' above an active-spinner footer does not fake an idle"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "$filler"$'\n'"  ⏵⏵ auto mode on")" \
        "A '⏵⏵ auto mode on' footer inside the window (no spinner) still matches"
}

# pane_pending_own_work exclusion (#517): a golem parked BETWEEN turns on its OWN
# background monitors / a running dynamic workflow / the review harness has no
# `esc to interrupt` spinner (its turn ended; the monitors are what it awaits) but
# is NOT awaiting a human — it has a queued next action. pane_is_turn_end must NOT
# classify it idle (rc 1), or the #447 push false-fires and trains the operator to
# ignore the signal. The two-poll debounce cannot help (the footer holds this shape
# across polls), so the matcher itself excludes. Every signature is anchored to the
# ACTUAL footer chrome via `grep -E` (a leading `·`/`,` separator before `N
# monitor`, the `Waiting for N dynamic workflow` prefix, an `N/M` fraction
# immediately before `agents done`) so ordinary completion prose that merely
# mentions those words — even with an INCIDENTAL digit nearby (a PR/issue number, a
# count) — does NOT suppress a genuine idle. The negative assertions pin exactly
# that: re-introducing the #517 false-NEGATIVE (a real idle silently swallowed)
# would be a regression, so they exercise the digit-adjacency traps the cycle-2
# review reproduced.
test_pane_is_turn_end_pending_own_work() {
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "⏵⏵ auto mode on · PR #514 · 1 shell, 1 monitor")" \
        "A '1 shell, 1 monitor' footer (own-work pending) is NOT idle (the golem-491 case)"
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "⏵⏵ auto mode on · PR #514 · 2 monitors")" \
        "A '2 monitors' footer (own-work pending) is NOT idle"
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "✻ Churned for 3h 32m · 1 shell, 1 monitor still running"$'\n'"  ⏵⏵ auto mode on")" \
        "A '1 monitor still running' churn footer is NOT idle"
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "Waiting for 1 dynamic workflow to finish"$'\n'"  ⏵⏵ auto mode on")" \
        "A 'Waiting for 1 dynamic workflow' wait (own-work pending) is NOT idle"
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "Waiting for the force-push notification to finish"$'\n'"  ⏵⏵ auto mode on")" \
        "A 'Waiting for … to finish' wait — the CI/force-push Monitor case — is NOT idle (issue's 2nd body pattern)"
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "next-issue-review  5/6 agents done"$'\n'"  ⏵⏵ auto mode on")" \
        "A 'N/6 agents done' review-harness footer is NOT idle"
    # Preserved true cases: ordinary completion prose — including prose with an
    # INCIDENTAL digit near the trigger word — must NOT suppress a genuine idle, or
    # the fix would re-introduce the #517 false-NEGATIVE it exists to prevent. These
    # are the exact digit-adjacency traps the cycle-2 review reproduced against a
    # bare case-glob (an unrelated digit + a later monitor/agents-done mention).
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "i'll start a monitor next"$'\n'"  ⏵⏵ auto mode on")" \
        "A bare-word 'monitor' in prose with an otherwise-idle footer STILL fires (real idle preserved)"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "Filed 3 monitor-related bugs today"$'\n'"  ⏵⏵ auto mode on")" \
        "An incidental 'N monitor'-adjacent prose (no chrome separator) STILL fires (real idle preserved)"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "Fixed the flaky test, 3 monitors were involved in triage."$'\n'"  ⏵⏵ auto mode on")" \
        "Comma-then-'N monitor' prose (NOT the 'N shell, N monitor' chrome) STILL fires (real idle preserved)"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "Review complete: 6 agents done."$'\n'"  ⏵⏵ auto mode on")" \
        "A bare '6 agents done.' idle summary (no N/M fraction) STILL fires (real idle preserved)"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "PR #12/34 merged, all agents done."$'\n'"  ⏵⏵ auto mode on")" \
        "An incidental 'N/M' PR number + later 'agents done' STILL fires (real idle preserved)"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "reviewed all 5 dynamic workflow docs"$'\n'"  ⏵⏵ auto mode on")" \
        "An incidental 'N dynamic workflow' prose (no 'Waiting for' prefix) STILL fires (real idle preserved)"
}

# pane_pending_own_work in isolation (#517): the raw predicate returns 0 only on a
# footer whose chrome actually advertises own-work — a `·`/`,` separator before
# `N monitor`, the `Waiting for N dynamic workflow` prefix, or an `N/M` fraction
# immediately before `agents done`. It returns 1 for everything else, INCLUDING
# prose that merely places an incidental digit near a trigger word (the cycle-2
# digit-adjacency traps), unanchored completion summaries, and an empty pane.
# Footer-anchored to the same window as its siblings.
test_pane_pending_own_work() {
    # Positives — real chrome.
    assert_equals "0" "$(_pane_rc pane_pending_own_work "⏵⏵ auto mode on · 1 monitor")" \
        "A '· N monitor' footer is own-work pending"
    assert_equals "0" "$(_pane_rc pane_pending_own_work "PR #514 · 3 monitors still running")" \
        "A '· N monitor still running' footer is own-work pending"
    assert_equals "0" "$(_pane_rc pane_pending_own_work "Waiting for 2 dynamic workflow to finish")" \
        "A 'Waiting for N dynamic workflow' wait is own-work pending"
    assert_equals "0" "$(_pane_rc pane_pending_own_work "Waiting for the force-push notification to finish")" \
        "A 'Waiting for … to finish' wait (no 'dynamic workflow') is own-work pending (issue's 2nd body pattern)"
    assert_equals "0" "$(_pane_rc pane_pending_own_work "next-issue-review 4/6 agents done")" \
        "An 'N/M agents done' harness footer is own-work pending"
    # Negatives — plain idle, bare-word prose, AND incidental-digit-adjacency traps
    # (the cycle-2 false positives a bare case-glob matched).
    assert_equals "1" "$(_pane_rc pane_pending_own_work "  ⏵⏵ auto mode on")" \
        "A plain idle footer is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "the monitor tool is handy")" \
        "A bare-word 'monitor' (no digit) is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "Filed 3 monitor-related bugs today")" \
        "An incidental '3 monitor'-adjacent prose (no chrome separator) is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "see issue #1 monitor config")" \
        "An incidental '1 monitor' in prose (no separator) is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "he noted, 4 monitors flagged issues")" \
        "A bare comma before 'N monitors' (NOT 'N shell, N monitor' chrome) is NOT own-work pending (cycle-3)"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "Fixed the setup, 2 monitors confirmed working.")" \
        "A comma-then-'N monitors' completion summary is NOT own-work pending (cycle-3)"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "Review complete: 6 agents done.")" \
        "A bare '6 agents done.' summary (no N/M fraction) is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "PR #12/34 merged, all agents done.")" \
        "An incidental 'N/M' + later 'agents done' is NOT own-work pending"
    assert_equals "1" "$(_pane_rc pane_pending_own_work "reviewed all 5 dynamic workflow docs")" \
        "An incidental 'N dynamic workflow' prose (no 'Waiting for') is NOT own-work pending"
    # Cross-line trap: a fraction on one line, 'agents done' on another, must NOT
    # match (grep is per-line; a case-glob would have matched across the newline).
    assert_equals "1" "$(_pane_rc pane_pending_own_work "Completed 4/6 setup steps"$'\n'"separately, 12 things agents done elsewhere")" \
        "An 'N/M' and 'agents done' on DIFFERENT lines do NOT match (per-line grep)"
}

# End-to-end turn-end dispatch (#447): drive the REAL panes_snapshot() via
# `--once-panes` (reusing _run_panes_snapshot_tmux) to pin that a turn-ended pane
# emits the idle-at-prompt label AND that it is the LAST-RESORT branch — a pane
# that is BOTH a modal overlay and shows the idle footer is classified as the
# overlay, never downgraded to idle.
test_panes_snapshot_turn_end_dispatch() {
    _run_panes_snapshot_tmux "⏺ done for now"$'\n'"  ⏵⏵ auto mode on"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a turn-ended pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ idle at prompt — turn ended, awaiting input (check pane)" \
        "A turn-ended pane emits the idle-at-prompt label end-to-end"

    # Plan overlay + idle footer: plan-gate is checked first, so it wins.
    _run_panes_snapshot_tmux "1. Yes, and use auto mode"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan+idle pane emits the plan-gate label (plan wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A plan+idle pane is NOT downgraded to idle-at-prompt"

    # Permission-gate + idle footer: the generic gate is checked before turn-end,
    # so it wins (turn-end is the 4th-tier last resort, must lose to ANY modal).
    _run_panes_snapshot_tmux "Do you want to proceed?"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"permission gate — awaiting decision" \
        "A gate+idle pane emits the permission-gate label (gate wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A gate+idle pane is NOT downgraded to idle-at-prompt"

    # Fork + idle footer: the escalation fork is checked before turn-end, so it wins.
    _run_panes_snapshot_tmux "What scope? "$'\n'"Enter to select · ↑/↓ to navigate"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "A fork+idle pane emits the escalation label (fork wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A fork+idle pane is NOT downgraded to idle-at-prompt"

    # Own-work-pending + idle footer (#517): a golem parked on its own monitors
    # paints the bare turn-end footer but is NOT awaiting a human — panes_snapshot
    # must emit NO idle line for it (pane_pending_own_work excludes it inside
    # pane_is_turn_end, the last-resort branch).
    _run_panes_snapshot_tmux "⏺ working"$'\n'"  ⏵⏵ auto mode on · PR #514 · 1 shell, 1 monitor"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A pane parked on its own monitors is NOT pushed as idle-at-prompt (#517)"
    assert_not_contains "$PANES_OUT" "golem-9" \
        "An own-work-pending pane emits no golem line at all (silent, not idle)"
}

# confirm_turn_end two-consecutive-poll debounce (#447): the turn-end/idle line is
# suppressed on the FIRST poll a golem looks idle and passed only once it is STILL
# idle on the NEXT poll — so a momentary between-turns render never fires a false
# idle. Real gates pass through immediately (they do not flicker). A golem that
# clears re-confirms from scratch. Also covers a multi-golem single call (shared
# accumulators don't cross-clobber) and the chained confirm_turn_end ->
# emit_transitions drive-arm sequence (a fresh idle surfaces once, on its 2nd
# poll). Like test_emit_transitions_dedup, all cases run in ONE subshell because
# PENDING_TURN_END / LAST_EMIT are module state mutated across calls.
test_confirm_turn_end_debounce() {
    local out
    # The literal turn-end message (the sourced $TURN_END_MSG is only in scope
    # inside the subshell below; assertions in this outer scope use the literal).
    local te="⚠ idle at prompt — turn ended, awaiting input (check pane)"
    out="$(
        source "$GATE_WATCH"
        local idle="golem-3"$'\t'"$TURN_END_MSG"
        # 1. First idle poll -> suppressed (CONFIRMED_SNAPSHOT empty).
        command printf '[p1]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 2. Second consecutive idle poll -> confirmed (passes through).
        command printf '[p2]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 3. A real gate passes through on its FIRST poll (no debounce). NOTE this
        #    snapshot omits golem-3, so golem-3 also DROPS from PENDING_TURN_END here
        #    (nextpending is rebuilt from scratch each call from only the lines in
        #    this snapshot) — the clear happens at this step, not case 4.
        command printf '[gate]'
        confirm_turn_end "golem-4"$'\t'"permission gate — awaiting decision"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 4. A genuinely empty snapshot after the clear is a no-op; the FIRST idle
        #    poll for golem-3 after it dropped is suppressed again (re-confirms from
        #    scratch, not remembered across the clear).
        command printf '[clear]'
        confirm_turn_end ""
        command printf '[reidle1]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 5. Multi-golem SINGLE call: two idle golems + one real gate in ONE snapshot.
        #    Pins that the per-line loop's shared accumulators do not let one golem's
        #    line clobber another's pending flag / passthrough within a single call.
        #    golem-3 was left pending by case 4's reidle1; golem-7 is fresh. So this
        #    one call must: confirm golem-3 (its 2nd consecutive idle), suppress
        #    golem-7 (its 1st idle), and pass golem-8's gate straight through.
        command printf '[multi]'
        confirm_turn_end "golem-3"$'\t'"$TURN_END_MSG"$'\n'"golem-7"$'\t'"$TURN_END_MSG"$'\n'"golem-8"$'\t'"permission gate — awaiting decision"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 6. Chained drive-arm sequence: confirm_turn_end -> emit_transitions in the
        #    SAME shell, exactly as the --stream-panes arm wires it, across two polls.
        #    Pins that emit_transitions reads the CONFIRMED (post-debounce) snapshot,
        #    so a fresh idle golem surfaces on its SECOND poll and only ONCE (dedup).
        #    golem-5 is a fresh id (never in PENDING_TURN_END above) and LAST_EMIT is
        #    still empty here (earlier cases call only confirm_turn_end), so no state
        #    reset is needed.
        command printf '[chain1]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
        command printf '[chain2]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
        command printf '[chain3]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
    )"
    assert_contains "$out" "[p1][p2]" \
        "The first idle poll emits nothing (suppressed pending confirmation)"
    assert_contains "$out" "[p2]golem-3"$'\t'"$te" \
        "The second consecutive idle poll confirms and passes the turn-end line"
    assert_contains "$out" "[gate]golem-4"$'\t'"permission gate — awaiting decision" \
        "A real gate passes through on its first poll (not debounced)"
    assert_not_contains "$out" "[reidle1]golem-3" \
        "After a clear, a single idle poll is suppressed again (re-confirms from scratch)"
    # Multi-golem single call: golem-3 confirmed, golem-7 suppressed, golem-8 gate through.
    assert_contains "$out" "[multi]golem-3"$'\t'"$te" \
        "In a multi-golem call, a golem on its 2nd consecutive idle is confirmed"
    assert_contains "$out" "golem-8"$'\t'"permission gate — awaiting decision" \
        "In the same multi-golem call, a real gate still passes straight through"
    assert_not_contains "$out" "[multi]golem-7" \
        "In the same multi-golem call, a golem on its 1st idle is still suppressed"
    # Chained sequence: golem-5 surfaces once, on chain2 (its 2nd poll), not chain1/3.
    assert_not_contains "$out" "[chain1]golem-5" \
        "Chained drive-arm: a fresh idle golem does not surface on its first poll"
    assert_contains "$out" "[chain2]golem-5"$'\t'"$te" \
        "Chained drive-arm: the idle golem surfaces on its second poll (post-debounce)"
    assert_not_contains "$out" "[chain3]golem-5" \
        "Chained drive-arm: the standing idle line is deduped by emit_transitions (not re-emitted)"
}

# emit_transitions: the transition-dedup contract that backs --stream/--stream-
# panes. All cases run inside ONE subshell because LAST_EMIT is module state the
# function mutates across calls; the subshell isolates that from the harness.
#   1. prime=1 records state WITHOUT emitting (startup must not replay standing gates)
#   2. a NEW golem (or changed message) emits exactly its line
#   3. a STANDING gate (same golem+message) is suppressed on the next tick
#   4. a changed message for the same golem re-emits
#   5. a golem that CLEARS then re-gates is a fresh transition (emits again)
test_emit_transitions_dedup() {
    local out
    out="$(
        source "$GATE_WATCH"
        # 1. Prime with one standing gate -> no output.
        command printf '[prime]'
        emit_transitions "$(command printf 'golem-1\tpush gate\n')" 1
        # 2. Same gate on the next tick -> suppressed (already primed).
        command printf '[standing]'
        emit_transitions "$(command printf 'golem-1\tpush gate\n')" 0
        # 3. A genuinely new golem -> emits.
        command printf '[new]'
        emit_transitions "$(command printf 'golem-1\tpush gate\ngolem-2\tPR gate\n')" 0
        # 4. golem-1's message changes -> re-emits; golem-2 unchanged -> silent.
        command printf '[changed]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\ngolem-2\tPR gate\n')" 0
        # 5. golem-2 clears (empty snapshot for it) then re-gates -> fresh emit.
        command printf '[clear]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\n')" 0
        command printf '[regate]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\ngolem-2\tPR gate\n')" 0
    )"
    # Prime + standing emit nothing between their markers.
    assert_contains "$out" "[prime][standing][new]" \
        "Prime and standing gate emit nothing (no replay on startup or steady state)"
    assert_contains "$out" "[new]golem-2"$'\t'"PR gate" \
        "A newly-gated golem emits its line"
    assert_contains "$out" "[changed]golem-1"$'\t'"merge gate" \
        "A changed message re-emits for the same golem"
    assert_not_contains "$out" "[changed]golem-1"$'\t'"merge gate"$'\n'"golem-2" \
        "An unchanged golem is not re-emitted alongside a changed one"
    assert_contains "$out" "[regate]golem-2"$'\t'"PR gate" \
        "A cleared-then-re-gated golem is a fresh transition"
}
