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

# pane_is_multi_question_form (#467): a 2+-question AskUserQuestion form paints a
# tabbed widget (`☐`/`☒` checkboxes + a `✔ Submit` tab) over the SAME
# `Enter to select` footer a single-question fork paints. Both signals are
# required, and each half of the conjunction is pinned by a case that carries
# only the other — a matcher satisfied by either alone would false-fire on a
# plain fork (mislabelling every ordinary escalation) or on scrollback chrome.
test_pane_is_multi_question_form() {
    local form="☐ Commit-back  ☒ Edit strategy  ✔ Submit"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$(_pane_rc pane_is_multi_question_form "$form")" \
        "A tabbed multi-question form (checkbox glyphs + fork footer) matches"
    # MULTI_Q_RE has THREE alternatives and each is pinned by a fixture that
    # carries ONLY that one — otherwise an alternative could be deleted with the
    # suite still green (the untested-rule class). The checkbox arm is covered by
    # $form above; the other two follow.
    #
    # Arm 2 — the `←` scroll-arrow rendering. Claude Code paints the tab bar with
    # scroll arrows when the questions overflow the pane width, so the line no
    # longer STARTS with a checkbox. Without the optional `←` prefix in the regex
    # the anchor misses, and a wide two-question form silently reads as an
    # ordinary fork — the exact bug the anchoring was added to prevent, arriving
    # by a different route.
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "← ☐ Commit-back  ☒ Edit strategy  ✔ Submit →"$'\n'"Enter to select")" \
        "The scroll-arrow (←) tab-bar rendering is still a multi-question form"
    # Arm 3 — the unanswered-questions warning, carrying NO checkbox glyph, so it
    # is this alternative alone that matches. This is the review screen: the most
    # dangerous state to misclassify, since it is where a stray Enter submits a
    # half-answered form.
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "⚠ You have not answered all questions"$'\n'"Enter to select")" \
        "The unanswered-questions warning is also a widget signal"

    # Footer without a widget glyph = the ORDINARY single-question fork, which
    # pane_is_fork already handles. This is the case that keeps the new matcher
    # from swallowing every escalation.
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form "What scope? "$'\n'"Enter to select · ↑/↓ to navigate")" \
        "A single-question fork (footer, no widget glyph) is NOT a multi-question form"
    # Glyph without the selection footer = not a modal at all.
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form "☒ done"$'\n'"just some scrolling build output")" \
        "A checkbox glyph alone (no fork footer) is NOT a multi-question form"
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form "just some scrolling build output")" \
        "Unrelated work output is NOT a multi-question form"
}

# #986 — the FALSE-POSITIVE direction: a SINGLE-question form is not multi.
#
# The #467 fixtures above all happen to carry two signals (two checkboxes, or a
# checkbox plus `✔ Submit`), so nothing pinned the one-question case. A
# single-question AskUserQuestion also paints a line starting with `☐`, and the
# original line-anchored MULTI_Q_RE matched it — observed live on golem-699,
# which was labelled "escalation (multi-question form)" with questions=1.
#
# Harm is LOW in this direction (a broker warned off the digit still reads the
# form and answers correctly), which is exactly why it needs a test: nothing in
# production surfaces it. The second assertion is the one that keeps the fix
# honest — narrowing the regex must not DROP the gate, only relabel it, so the
# pane must still be detected as the ordinary fork it is.
test_pane_multi_question_form_single_question_not_multi() {
    # The golem-699 shape: one checkbox line plus the inline option preview.
    local single=" ☐ Share mechanism"$'\n'"❯ 1. Runtime delegation"$'\n'"  2. Copy the file"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$single")" \
        "A single-question form rendering ONE ☐ line is NOT a multi-question form (#986)"
    assert_equals "0" "$(_pane_rc pane_is_fork "$single")" \
        "...and it is still detected as the ordinary fork (relabelled, not dropped)"

    # End-to-end: the dispatch chain must emit the plain fork label for it.
    _run_panes_snapshot_tmux "$single"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "panes_snapshot labels a single-question form a plain fork (#986)"
    assert_not_contains "$PANES_OUT" "multi-question form" \
        "panes_snapshot does not mislabel a single-question form as multi (#986)"
}

# #986 — the FALSE-NEGATIVE direction. NAMED for it deliberately: this is the
# direction that RESOLVES A GATE WRONGLY. A real two-question form going
# unlabelled sent the orchestrator a bare `1` (golem-902), which answered Q1 and
# jumped to the review screen with Q2 still `☐` and Submit focused — one more
# Enter submits a half-answered form the golem acts on as the operator's
# decision.
#
# READ THIS BEFORE TRUSTING A GREEN RUN. The first assertion below PASSES AGAINST
# THE PRE-#986 REGEX TOO (measured: old=1, new=1). AC 2 as written is satisfied by
# the code this issue was filed against, so this test being green is NOT evidence
# the false negative is fixed. It is a guard against REGRESSION — the narrowing
# must not break the multi case while fixing the single one.
#
# The live false negative is NOT in this regex and is not fixed here: with the
# tab bar absent from the capture entirely (0 of 229 live modal captures carried
# a glyph — capture-pane runs without -S, so an overflowing form scrolls its bar
# off the top), no pattern can match it. See
# docs/verification/multi-question-capture-e2e-986.md and #1010.
test_pane_multi_question_form_false_negative_two_question_bar() {
    # The golem-902 bar. Matches under BOTH the old and new regex — regression
    # guard only, NOT proof the FN is fixed (see the block above).
    local bar="←  ☒ Follow-up  ☐ Issue repo  ✔ Submit  →"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$(_pane_rc pane_is_multi_question_form "$bar")" \
        "A two-question tab bar IS labelled multi (regression guard; passes pre-#986 too)"

    # AC 3 — scrolled so only ONE tab is visible, but `✔ Submit` still present.
    # This is why the second conjunct accepts Submit as well as a second checkbox.
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "←  ☒ Follow-up  ✔ Submit  →"$'\n'"Enter to select")" \
        "A bar scrolled to one tab but carrying ✔ Submit is still multi (#986 AC3)"
    # Extreme scroll: no checkbox visible at all, only the Submit tab. Covered by
    # its own arm, which needs no second conjunct because a line starting with ✔
    # is a shape prose never takes (measured: 0 occurrences in the repo, with the
    # arrow optional).
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "←  ✔ Submit  →"$'\n'"Enter to select")" \
        "A bar scrolled to the Submit tab alone is still multi (#986)"
    # ...and WITHOUT the leading arrow. A bar scrolled to its LAST tab may render
    # no `←` (nothing further right to scroll to). The arm originally required the
    # arrow while the comment above it claimed only "starts with ✔" — a comment
    # asserting a guarantee the code did not provide, which would have missed this
    # pane silently. Pins the arrow as OPTIONAL in the arm.
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "  ✔ Submit"$'\n'"Enter to select")" \
        "A bare '✔ Submit' line with NO scroll arrow is still multi (#986 review)"

    # Isolates the SECOND-CHECKBOX alternative of the new same-line conjunct
    # `(☐|☒|✔ Submit)`. Every other fixture exercising that conjunct carries BOTH
    # a second checkbox AND `✔ Submit`, so none of them can tell which alternative
    # fired: deleting the `(☐|☒)` option left the whole suite GREEN (measured).
    # That is the untested-rule class this file's own comment at the head of
    # test_pane_is_multi_question_form warns about, applied to the inner
    # alternation #986 added. The fixture below carries two checkboxes and NO
    # Submit tab — the real rendering of a bar scrolled so Submit is off-screen.
    assert_equals "0" \
        "$(_pane_rc pane_is_multi_question_form "←  ☐ Q1  ☒ Q2  →"$'\n'"Enter to select")" \
        "Two checkboxes with NO ✔ Submit visible is still multi (#986 review)"

    # NEGATIVE guard for the loosened arm (#986 review cycle 2). Dropping the
    # mandatory `←` widened the match surface, so the arm now needs a boundary the
    # arrow used to supply for free: the tab label is the WORD `Submit`, and
    # without `([^[:alnum:]]|$)` an ordinary progress line starting with `✔`
    # matches. Measured: `✔ Submitted 3 files` and `✔ Submitting…` were old=0 ->
    # new=1 under the arrow-optional arm before the boundary was added — a false
    # positive INTRODUCED by the loosening, not pre-existing. Removing the
    # boundary turns these two assertions red.
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form "✔ Submitted 3 files"$'\n'"Enter to select")" \
        "A '✔ Submitted …' progress line is NOT a Submit tab (#986 review cycle 2)"
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form "  ✔ Submitting..."$'\n'"Enter to select")" \
        "A '✔ Submitting…' progress line is NOT a Submit tab (#986 review cycle 2)"

    # End-to-end: the form label must win over the fork label for this pane.
    _run_panes_snapshot_tmux "$bar"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation (multi-question form) — forward-order only, never a digit" \
        "panes_snapshot emits the form label for a two-question bar (#986)"
}

# #1010 — THE SCROLLED-OFF-TOP CASE. Named for it deliberately, to separate it
# from the #986 regex cases above: those are about what the PATTERN matches, this
# is about what the CAPTURE contains. `tmux capture-pane -p` returns only the
# VISIBLE pane, so a form whose option text overflows the pane height scrolls its
# `☐/☒ … ✔ Submit` tab bar off the TOP, where no window a `tail` can take will
# ever reach it. Every regex necessarily misses; the fix is Guard 3's own `-S`
# read.
#
# THE FIXTURES BELOW ARE REAL CAPTURED PANES (AC 4), not hand-written chrome.
# That constraint is not decorative: #986 reached a FALSE conclusion twice from
# hand-written fixtures, because an invented chrome stack copied the WORKING
# session's status bar, which a live modal does not paint. These two strings are
# `capture-pane -p` and `capture-pane -p -S -120` of the same instant in
# golem-1010 (24-row pane), taken while a genuine two-question AskUserQuestion
# modal was up. 152 of 180 paired snapshots reproduced this exact shape; the bar
# sat at depth 43 from the bottom in every one of them —
# docs/verification/multi-question-capture-scrollback-e2e-1010.md.
#
# Depth 43 is also why the existing 40-line $pane_error_lines window could not
# have been reused as the scrollback depth: the measured bar falls three lines
# outside it.
#
# _mq_1010_visible / _mq_1010_scrollback — the captured pair. Built as functions
# rather than file fixtures so the suite stays self-contained, and the widget
# lines are assembled from a leading-space-stripped form so this test file itself
# contains NO line-initial widget shape (a repo-wide scan measures zero, and a
# fixture that broke that would make this very file self-trip the matcher it
# tests).
#
# ONE DEVIATION FROM VERBATIM, recorded so nobody reads it as invention: the pane
# wrapped "two-question" mid-word across two rows, and the orphaned fragment trips
# the repo's `typos` gate. The two rows are rejoined. The fragment carries no
# glyph and no assertion reads it — what these fixtures are FOR is the glyph line
# and its position relative to the prose, both of which are untouched.
_mq_1010_visible() {
    command printf '%s\n' \
        "     needs its own negative fixtures." \
        "  2. Widen the shared capture with -S, re-verify all nine" \
        "     Add \`-S -N\` to the shared \`capture-pane\` in panes_snapshot and the liveness" \
        "     reader, feeding scrollback to every matcher. Simplest diff by far, but it" \
        "  4. Type something." \
        "  5. Chat about this" \
        "" \
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"
}
# The same pane read with scrollback. Carries, in capture order: glyph-bearing
# PROSE (the two lines a golem reading this repo's own files produces), then the
# genuine tab bar, then the modal body. The prose sits ABOVE the bar exactly as
# captured — which is what makes this one fixture serve as both the positive case
# and the self-trip case.
_mq_1010_scrollback() {
    command printf '%s\n' \
        "  ⎿  invoked with no \`-S\`, so it returns only the **visible** pane. A two-question" \
        "     form with real option text is taller than 24 rows, so the \`☐/☒ … ✔ Sub" \
        "     … +59 lines (ctrl+o to expand)" \
        "  fixture the ACs require." \
        "←  ☐ Capture fix  ☐ Window size  ✔ Submit  →" \
        "" \
        "│ The tab bar is outside the captured pane entirely, so no regex can reach it." \
        "  4. Type something." \
        "  5. Chat about this" \
        "" \
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"
}

test_pane_multi_question_form_scrolled_off_top() {
    local visible scrollback
    visible="$(_mq_1010_visible)"
    scrollback="$(_mq_1010_scrollback)"

    # THE BUG, REPRODUCED. Text-only (no session) is precisely the pre-#1010 code
    # path, and on the real captured pane it MISSES. This assertion is what makes
    # the next one meaningful: without it a green suite could not tell a working
    # scrollback read from a fixture that was always going to match.
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$visible")" \
        "The real captured VISIBLE pane misses the form (#1010, the bug)"

    # THE FIX. Same visible text, plus a session whose scrollback holds the bar.
    assert_equals "0" \
        "$(_pane_rc_sess pane_is_multi_question_form "$visible" "$scrollback")" \
        "With the scrollback read, the same pane IS labelled a multi-question form (#1010)"

    # The counterfactual that makes the harm concrete: the visible pane matches
    # pane_is_fork, so before the fix the operator was told this two-question form
    # was an ordinary single-question escalation and brokered it with a digit.
    assert_equals "0" "$(_pane_rc pane_is_fork "$visible")" \
        "...and the visible pane reads as a plain fork, which is the mislabel (#1010)"

    # End-to-end through the real dispatch chain: the form label must win.
    PANE_TEXT_S="$scrollback" _run_panes_snapshot_tmux "$visible"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation (multi-question form) — forward-order only, never a digit" \
        "panes_snapshot emits the form label for a scrolled-off-top form (#1010)"
    assert_not_contains "$PANES_OUT" "escalation — awaiting decision (carries options)" \
        "panes_snapshot no longer emits the plain fork label for it (#1010)"
}

# THE NEGATIVE THAT #1010 NEWLY REQUIRES. Before this issue the glyph scan saw
# only the visible pane, so prose had to be ON SCREEN to self-trip it. It now
# reads SCROLLBACK — where a golem's recently-read file content lives — so
# MULTI_Q_RE's `^` anchoring became load-bearing in a way the existing self-trip
# fixtures (written against the visible pane) do not cover.
#
# Every fixture below is real text: the two prose lines from the live capture,
# and lines from escalation-protocol.md, monitor-protocol.md and
# golem-gate-watch.sh's own comment block — the files a golem actually reads
# while working this area. Each is placed in SCROLLBACK under an ordinary
# single-question fork. Removing an anchor from MULTI_Q_RE turns this red.
test_pane_multi_question_form_scrolled_off_top_prose() {
    local fork prose
    fork="What scope should this take?"$'\n'"Enter to select · ↑/↓ to navigate"

    # The captured prose lines, WITHOUT the genuine bar that followed them.
    prose="$(command printf '%s\n' \
        "  ⎿  invoked with no \`-S\`, so it returns only the **visible** pane. A two-question" \
        "     form with real option text is taller than 24 rows, so the \`☐/☒ … ✔ Sub" \
        "  ... more file content")"
    assert_equals "1" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$prose")" \
        "Captured glyph-bearing prose in SCROLLBACK does not fake a form (#1010)"

    # Skills prose, copied from escalation-protocol.md / monitor-protocol.md.
    local skills
    skills="$(command printf '%s\n' \
        "  a form carrying 2+ questions renders as a tabbed widget (☐/☒ per question, a ✔ Submit tab)" \
        "  answer forward-order with ↑/↓+Enter and submit only at all-☒" \
        "  ... more file content")"
    assert_equals "1" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$skills")" \
        "Skills prose describing the widget, read into SCROLLBACK, is not a form (#1010)"

    # The unanswered-questions warning quoted mid-sentence, as monitor-protocol.md
    # carries it. The warning arm needs its own scrollback negative — the checkbox
    # arm's immunity above says nothing about it.
    local warn
    warn="$(command printf '%s\n' \
        '- **The review screen offers `Submit` while questions are unanswered** ("⚠ You' \
        '  have not answered all questions"). One stray Enter submits a form.')"
    assert_equals "1" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$warn")" \
        "The warning quoted mid-sentence in SCROLLBACK is not a form (#1010)"

    # ...and the pane is still correctly labelled the plain fork it actually is,
    # so the guard did not trade a mislabel for a dropped gate.
    PANE_TEXT_S="$skills" _run_panes_snapshot_tmux "$fork"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "panes_snapshot still labels it a plain fork despite the scrollback prose (#1010)"
    assert_not_contains "$PANES_OUT" "multi-question form" \
        "panes_snapshot does not mislabel scrollback prose as a form (#1010)"
}

# $pane_scrollback_lines: the DEPTH asked of `capture-pane -S`, pinned exactly and
# both ways, mirroring the discipline #459 established for the footer window and
# #467 for the error window.
#
# The knob is exercised through the STUB, which echoes back whatever it is given —
# so what this pins is the `${GOLEM_PANE_SCROLLBACK_LINES:-100}` wiring reaching
# the `-S` argument, via a stub that returns the bar only when the requested depth
# is deep enough. A hardcoded 100, or a typo'd variable name, leaves the override
# silently unexercised — the same gap #467 found in the error window.
test_pane_multi_question_form_scrollback_window() {
    local fork bar
    fork="What scope should this take?"$'\n'"Enter to select"
    bar="←  ☐ Capture fix  ☐ Window size  ✔ Submit  →"

    # Default depth: the stub serves the bar, so the form is detected.
    assert_equals "0" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$bar")" \
        "The default scrollback depth reaches a bar in scrollback (#1010)"

    # Shrink: a depth too small to reach the bar must NOT detect it. The stub is
    # depth-aware, returning nothing below the requested threshold.
    assert_equals "1" \
        "$(MQ_STUB_MIN_DEPTH=50 GOLEM_PANE_SCROLLBACK_LINES=10 \
            _pane_rc_sess pane_is_multi_question_form "$fork" "$bar")" \
        "GOLEM_PANE_SCROLLBACK_LINES=10 is too shallow to reach the bar (#1010)"

    # Enlarge: the SAME pane matches once the depth is widened past the threshold,
    # which is what proves the env var reached the `-S` argument rather than the
    # matcher failing for an unrelated reason.
    assert_equals "0" \
        "$(MQ_STUB_MIN_DEPTH=50 GOLEM_PANE_SCROLLBACK_LINES=200 \
            _pane_rc_sess pane_is_multi_question_form "$fork" "$bar")" \
        "GOLEM_PANE_SCROLLBACK_LINES=200 reaches the same bar (#1010)"
}

# MULTI-SESSION DISPATCH (#1010 review cycle 2). The single-call tests above pin
# that pane_is_multi_question_form reads the session it is HANDED; this pins that
# panes_snapshot hands it the right one. The two are different claims, and only
# this one exercises the loop: with exactly one live session a regression that
# forwarded a stale, hardcoded or off-by-one `$sess` still reads the only pane
# there is, so every assertion passes. Two sessions is the smallest fixture that
# can tell them apart.
test_panes_snapshot_multi_session_scrollback() {
    local visible scrollback
    visible="$(_mq_1010_visible)"
    scrollback="$(_mq_1010_scrollback)"

    # Two live golems; ONLY golem-8 has the tab bar in its scrollback. Both paint
    # the same visible footer, so the visible read cannot distinguish them — the
    # label must follow the scrollback, and therefore the session targeting.
    TMUX_LS="golem-8: 1 windows"$'\n'"golem-9: 1 windows" \
        PANE_TEXT_S="$scrollback" PANE_TEXT_S_SESSION="golem-8" \
        _run_panes_snapshot_tmux "$visible"

    assert_contains "$PANES_OUT" "golem-8"$'\t'"escalation (multi-question form) — forward-order only, never a digit" \
        "The session whose SCROLLBACK holds the bar is labelled a form (#1010)"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "Its sibling, with no bar in scrollback, stays a plain fork (#1010)"
    assert_not_contains "$PANES_OUT" "golem-9"$'\t'"escalation (multi-question form)" \
        "The form label does not leak onto the sibling session (#1010)"
}

# THE STALE-BAR WINDOW (#1010 review cycle 2). Guards 1-2 and Guard 3 read the
# pane at two different instants, and nothing ties the bar Guard 3 finds to the
# widget that painted the footer Guards 1-2 saw. So a form the golem ALREADY
# answered leaves its tab bar in scrollback, and a later ORDINARY fork is
# labelled a form.
#
# MEASURED, NOT REASONED: an earlier draft of the comment above this matcher
# claimed the two-read split "can only lose a detection, never invent one". This
# fixture is what falsified it. Kept as a pinned, deliberate tradeoff rather than
# a bug, because it is the SAFE direction — a fork labelled a form routes the
# operator to the careful broker, while a form labelled a fork (#1010 itself)
# sends a digit into a two-question widget and half-submits it. If someone later
# closes this window, this test should CHANGE, not be deleted: it is the record
# that the asymmetry was chosen.
test_pane_multi_question_form_stale_bar_in_scrollback() {
    local fork stale
    fork="What scope should this take?"$'\n'"Enter to select"
    # A bar from a form that was answered earlier, still sitting in scrollback.
    stale="←  ☐ Old  ☐ Form  ✔ Submit  →"$'\n'"  ... later output the golem produced ..."

    assert_equals "0" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$stale")" \
        "A stale tab bar in scrollback DOES label a later fork a form (#1010, known asymmetry)"

    # The same pane read WITHOUT the wider capture is an ordinary fork, which is
    # what makes this a property of the two-read split rather than of the regex.
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$fork")" \
        "...while the visible pane alone reads it as the plain fork it is (#1010)"
}

# THE SESSION MUST BE THE ONE IT WAS GIVEN (#1010 review). Guard 3's whole point
# is reading the RIGHT pane's scrollback, and until the stub honored `-t` nothing
# pinned that: a matcher forwarding a hardcoded literal, or the wrong element of a
# multi-session loop, answered from the same canned text and passed. The stub now
# owns its text under one session name and returns nothing for any other, so
# these two assertions bracket the behavior.
test_pane_multi_question_form_scrollback_session() {
    local fork bar
    fork="What scope should this take?"$'\n'"Enter to select"
    bar="←  ☐ Capture fix  ☐ Window size  ✔ Submit  →"

    # The stub owns the text under the session _pane_rc_sess passes (golem-9).
    assert_equals "0" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "$bar")" \
        "The scrollback read reaches the session it was handed (#1010)"

    # Give the text to a DIFFERENT session: the read must come back empty and the
    # matcher must fall back, not answer from another pane's scrollback. Reverting
    # the stub's `-t` branch turns this red while every other assertion stays green.
    assert_equals "1" \
        "$(MQ_STUB_SESSION=golem-other \
            _pane_rc_sess pane_is_multi_question_form "$fork" "$bar")" \
        "Scrollback belonging to ANOTHER session is not read (#1010 review)"
}

# A malformed GOLEM_PANE_SCROLLBACK_LINES must not silently disable the widened
# window (#1010 review). The value is concatenated into `-S -$n`, so a
# `-`-leading or non-numeric setting builds a token tmux rejects; the rejection
# degrades to the visible-pane fallback, which is safe but SILENT — the widened
# read would look like it simply was not working. The knob is validated back to
# its default instead, so a mistyped value still detects the form.
test_pane_multi_question_form_scrollback_malformed_knob() {
    local fork bar i filler deep
    fork="What scope should this take?"$'\n'"Enter to select"
    bar="←  ☐ Capture fix  ☐ Window size  ✔ Submit  →"

    # A bar the VISIBLE tail cannot reach, so only the scrollback read can match
    # it — which is what makes this assert the knob rather than the fallback.
    filler=""
    for i in $(seq 1 45); do filler="${filler}  filler line $i"$'\n'; done
    deep="${bar}"$'\n'"${filler}"

    local bad
    for bad in "" "abc" "-5" "0"; do
        assert_equals "0" \
            "$(GOLEM_PANE_SCROLLBACK_LINES="$bad" \
                _pane_rc_sess pane_is_multi_question_form "$fork" "$deep")" \
            "A malformed GOLEM_PANE_SCROLLBACK_LINES ('$bad') still reads scrollback (#1010 review)"
    done
}

# FAIL-OPEN, NOT FAIL-CLOSED, AND NEVER FAIL-INVENTED. Three ways the wider read
# can be unavailable — no session argument, no tmux on PATH, an empty capture —
# must each reproduce the pre-#1010 visible-pane verdict exactly. A detector that
# could not look wider has learned nothing extra, so it reports what the narrow
# check reports: it must not start returning 0 (a fabricated form, which would
# send the operator to the wrong broker for a gate that is not one), and it must
# not stop matching a bar that IS visible.
test_pane_multi_question_form_scrollback_fallback() {
    local visible_bar fork
    visible_bar="←  ☒ Follow-up  ☐ Issue repo  ✔ Submit  →"$'\n'"Enter to select"
    fork="What scope should this take?"$'\n'"Enter to select"

    # (a) Empty capture — the `-S` read returns nothing.
    assert_equals "0" \
        "$(_pane_rc_sess pane_is_multi_question_form "$visible_bar" "")" \
        "An EMPTY scrollback capture falls back to the visible pane, which matches (#1010)"
    assert_equals "1" \
        "$(_pane_rc_sess pane_is_multi_question_form "$fork" "")" \
        "An EMPTY scrollback capture does not fabricate a form from a plain fork (#1010)"

    # (b) No session argument at all — every pre-#1010 text-only caller.
    assert_equals "0" "$(_pane_rc pane_is_multi_question_form "$visible_bar")" \
        "A text-only call (no session) still matches a VISIBLE bar (#1010)"
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$fork")" \
        "A text-only call does not fabricate a form from a plain fork (#1010)"

    # (c) No tmux on PATH — a headless host. The matcher must degrade, not error.
    assert_equals "1" \
        "$(MQ_STUB_NO_TMUX=1 _pane_rc_sess pane_is_multi_question_form "$fork" "$visible_bar")" \
        "With NO tmux the wider read is skipped and the fork stays a fork (#1010)"
    assert_equals "0" \
        "$(MQ_STUB_NO_TMUX=1 _pane_rc_sess pane_is_multi_question_form "$visible_bar" "")" \
        "With NO tmux a VISIBLE bar is still matched from the pane text (#1010)"
}

# The motivating live failure (#467): DETECTION failed before keystrokes did. On
# a real two-question form the first capture-pane showed only ONE question — the
# `☐/☒` tab bar had scrolled ABOVE the 8-line footer window — so an orchestrator
# reading the footer alone would broker a two-question form believing it single.
# This is why the matcher follows the pane_is_api_error shape (footer-anchored
# veto + wider $pane_error_lines content scan) instead of being footer-anchored
# like its siblings. The second assertion is the counterfactual: a purely
# footer-anchored read of the SAME pane sees an ordinary fork, so a fix that
# narrowed this matcher to the footer would silently restore the bug.
test_pane_multi_question_form_above_footer() {
    local filler i scrolled
    filler=""
    for i in 1 2 3 4 5 6 7; do filler="${filler}  question body line $i"$'\n'; done
    scrolled="☐ Commit-back  ☒ Edit strategy  ✔ Submit"$'\n'"${filler}Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$(_pane_rc pane_is_multi_question_form "$scrolled")" \
        "A tab bar scrolled ABOVE the footer window is still detected (the #816 capture)"
    assert_equals "0" "$(_pane_rc pane_is_fork "$scrolled")" \
        "pane_is_fork sees only the footer and reads it as a single-question fork"
}

# Self-trip guard (#246/#452 class, applied to #467). Every trigger phrase and
# glyph in this matcher appears in golem-gate-watch.sh's own comments AND in this
# very test file, so a golem cat-ing or editing either would false-fire a gate
# push without the run-spinner veto. The veto is footer-anchored and checked
# FIRST: a golem actively working is never at a gate, whatever its scrollback
# holds.
test_pane_multi_question_form_no_self_trip() {
    local working="☒ Edit strategy  ✔ Submit"$'\n'"Enter to select · ↑/↓ to navigate"$'\n'"  ⏵⏵ esc to interrupt"
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$working")" \
        "A WORKING golem (run-spinner up) reading form text is not a gate"
}

# The two-signal conjunction is NOT self-guarding, and this is the case that
# proves it. The footer test and the glyph test run over different windows, so
# nothing ties the glyph to the widget that painted the footer: an ORDINARY
# single-question fork, preceded in scrollback by unrelated text containing a
# checkbox, satisfies both independently. With a bare `☐|☒|✔ Submit` scan that
# pane misclassifies as a multi-question form — sending the operator to
# cancel-then-relay for a gate that `send-keys` would have resolved fine.
#
# It is not a contrived fixture: the prose describing this feature
# (escalation-protocol.md, monitor-protocol.md, golem-gate-watch.sh's own comment
# block, and the fixtures in THIS file) all carry those glyphs literally, so a
# golem reading any of them at a normal fork self-trips. The scrollback line
# below is copied from escalation-protocol.md for exactly that reason.
#
# The fix is SHAPE: a real tab bar is its own line starting with a checkbox,
# while prose carries the glyphs mid-sentence. Removing the `^` anchors from
# MULTI_Q_RE turns this test red while every other #467 test stays green.
test_pane_multi_question_form_prose_scrollback() {
    local prose mid i pane
    prose="  a form carrying 2+ questions renders as a tabbed widget (☐/☒ per question, a ✔ Submit tab)"
    mid=""
    for i in 1 2 3 4 5; do mid="${mid}  ... more file content line $i"$'\n'; done
    pane="$prose"$'\n'"${mid}What scope should this take?"$'\n'"Enter to select · ↑/↓ to navigate"

    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$pane")" \
        "A single-question fork with glyph-bearing PROSE in scrollback is not a form"

    # The WARNING arm needs its own negative fixture — the checkbox arm's
    # immunity above says nothing about it. monitor-protocol.md quotes the
    # warning mid-sentence, so a golem reading that file at an ordinary fork is
    # the realistic self-trip. Both lines below are copied from it verbatim.
    local wprose wpane
    wprose='- **The review screen offers `Submit` while questions are unanswered** ("⚠ You'
    wpane="$wprose"$'\n''  have not answered all questions"). One stray Enter submits a form.'$'\n'"What scope?"$'\n'"Enter to select"
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$wpane")" \
        "Prose quoting the unanswered-questions warning mid-sentence is not a form"
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form 'the `⚠ You have not answered all questions` warning'$'\n'"Enter to select")" \
        "A backticked mention of the warning is not a form"

    # The `[^\`]` guard in the warning arm, pinned on the ONLY shape that can
    # exercise it: a LINE-INITIAL `⚠` whose text reaches "not answered all"
    # through a backtick. Every other backticked form is already rejected by the
    # `^` anchor, so without this fixture the guard is untestable-by-accident —
    # relaxing it to `.*` leaves the suite green (measured). This is prose the
    # widget never emits: the real warning carries no code span.
    assert_equals "1" \
        "$(_pane_rc pane_is_multi_question_form '⚠ the `Submit` button: you have not answered all questions'$'\n'"Enter to select")" \
        "A line-initial warning whose text crosses a backtick is prose, not the widget"
    # The pane must still be recognized as the ordinary fork it actually is —
    # otherwise the fix would have traded a mislabel for a dropped gate.
    assert_equals "0" "$(_pane_rc pane_is_fork "$pane")" \
        "...and it is still detected as an ordinary single-question fork"

    # End-to-end: the dispatch chain must emit the plain fork label for it.
    _run_panes_snapshot_tmux "$pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "panes_snapshot labels it a plain fork, not a multi-question form"
    assert_not_contains "$PANES_OUT" "multi-question form" \
        "panes_snapshot does not mislabel it a multi-question form"
}

# $pane_error_lines window: exact boundary + env override (#467, mirroring #459's
# test_pane_footer_lines_env_overridable for the footer window).
#
# This matcher's glyph scan is the SECOND consumer of `pane_error_lines`
# ("${GOLEM_PANE_ERROR_LINES:-40}", read once at source time) — pane_is_api_error
# was the first, and NOTHING pinned that knob before this test. So a per-matcher
# hardcoded 40, or a typo'd variable name, would leave the ${VAR:-default} wiring
# silently unexercised in both consumers. The window size is not cosmetic here:
# it is exactly how far above the footer a scrolled-away tab bar can sit and
# still be seen, which is the #467 failure this matcher exists to prevent.
#
# The boundary is pinned EXACTLY (no fencepost slop, the discipline #459
# established for the footer window): with the default 40-line window, glyph +
# 39 filler = 40 lines MATCHES, and one line more does not. Asserting both sides
# is what makes it a boundary rather than a smoke test — an off-by-one in the
# `tail -n` would keep the first assertion green.
test_pane_multi_question_form_error_window() {
    local i filler38 filler39 in_window out_window
    # Panes are: glyph line + N filler + footer line = N+2 total. The glyph sits
    # on the FIRST line, so it is inside a 40-line window iff N+2 <= 40, i.e.
    # N <= 38. Hence 38 filler (40 lines, glyph exactly at the window edge) is
    # the last matching case and 39 filler (41 lines) is the first that is not.
    filler38=""
    for i in $(seq 1 38); do filler38="${filler38}  filler line $i"$'\n'; done
    filler39="${filler38}  filler line 39"$'\n'

    in_window="☒ Q1  ✔ Submit"$'\n'"${filler38}Enter to select"
    out_window="☒ Q1  ✔ Submit"$'\n'"${filler39}Enter to select"

    assert_equals "0" "$(_pane_rc pane_is_multi_question_form "$in_window")" \
        "A glyph on the 40th-from-last line is INSIDE the default error window"
    assert_equals "1" "$(_pane_rc pane_is_multi_question_form "$out_window")" \
        "One line further up is OUTSIDE it (the boundary is exact, no slop)"

    # Enlarge direction: the SAME out-of-window pane matches once the window is
    # widened, which is what proves the env var reached the source-time read
    # rather than the matcher simply failing for some unrelated reason.
    assert_equals "0" \
        "$(GOLEM_PANE_ERROR_LINES=60 _pane_rc pane_is_multi_question_form "$out_window")" \
        "GOLEM_PANE_ERROR_LINES=60 enlarges the window so the same glyph falls inside it"
    # Shrink direction, so the wiring is pinned both ways: the in-window pane
    # stops matching under a window too small to reach the glyph.
    assert_equals "1" \
        "$(GOLEM_PANE_ERROR_LINES=10 _pane_rc pane_is_multi_question_form "$in_window")" \
        "GOLEM_PANE_ERROR_LINES=10 shrinks the window so the same glyph falls outside it"
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

# panes_snapshot dispatch for the multi-question form (#467). THIS is the test
# the branch order depends on: a form paints the fork's `Enter to select` footer
# too, so pane_is_fork matches it as well (pinned in
# test_pane_multi_question_form_above_footer). Only the DISPATCH ORDER decides
# which label the operator sees, and a unit rc check cannot observe order — move
# the form branch after the fork branch and every assertion below still passes at
# the matcher level while the emitted label silently regresses to a plain
# "escalation", sending the operator to the single-question brokers that resolve
# this widget WRONG (a partial submit).
#
# The label is asserted in full, not by substring: the whole point is that it
# carries the keystroke rule (forward-order, never a digit), so a truncated or
# reworded label that dropped it would still pass a substring check.
test_panes_snapshot_multi_question_dispatch() {
    _run_panes_snapshot_tmux "☐ Commit-back  ☒ Edit strategy  ✔ Submit"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a multi-question form pane"
    assert_contains "$PANES_OUT" \
        "golem-9"$'\t'"escalation (multi-question form) — forward-order only, never a digit" \
        "A multi-question form emits the form label naming the correct broker"
    assert_not_contains "$PANES_OUT" "escalation — awaiting decision (carries options)" \
        "A form is NOT downgraded to the single-question fork label (order: form before fork)"

    # The converse, so the new branch is narrow: an ordinary single-question fork
    # must STILL get the plain fork label. Without this a matcher that matched
    # every fork would pass the assertions above and relabel all escalations.
    _run_panes_snapshot_tmux "What scope? "$'\n'"Enter to select · ↑/↓ to navigate · Esc to cancel"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "A single-question fork still emits the plain fork label (new branch is narrow)"
    assert_not_contains "$PANES_OUT" "multi-question form" \
        "A single-question fork is NOT labelled a multi-question form"

    # Precedence above the new branch is unchanged: a plan overlay that also
    # carries widget chrome is still a plan gate.
    _run_panes_snapshot_tmux "1. Yes, and use auto mode"$'\n'"☒ Q1  ✔ Submit"$'\n'"Enter to select"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan overlay carrying widget chrome is still a plan gate (plan wins)"
    assert_not_contains "$PANES_OUT" "multi-question form" \
        "A plan gate is NOT downgraded to a multi-question form"
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
