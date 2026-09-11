# Multi-question form scrolled off the visible pane — live reproduction and fix (#1010)

**Date:** 2026-09-10
**Session:** `golem-1010` (tmux, 24-row pane)
**Companion to:** `multi-question-capture-e2e-986.md`, which established that the
tab bar is absent from the capture; this file reproduces that miss as a matched
pair, measures how far up the bar actually sits, and records the fix.

**Why this file exists:** the measurement cannot be re-derived from a test run.
Every fixture in `tests/gate-watch/` is text a human typed; what is recorded here
is what `tmux capture-pane` *actually returns* for a real Claude Code
`AskUserQuestion` modal, at two different capture depths taken at the same
instant. #986 reached a **false** conclusion twice from hand-written fixtures
before a live capture corrected it, so the fixtures in
`test_pane_multi_question_form_scrolled_off_top` are lifted from the captures
below rather than invented.

## Method

A genuine **two-question** `AskUserQuestion` modal was raised in `golem-1010`
while a background loop took **180 paired snapshots** at 1 s intervals:

```bash
tmux capture-pane -p            -t golem-1010   # visible pane  (what the code read)
tmux capture-pane -p -S -120    -t golem-1010   # with scrollback
```

The modal was raised by the agent's own `AskUserQuestion` call — not a mock, not
a printed approximation. Pairing the two depths at the same instant is what makes
the finding a *capture* result rather than a *timing* one: both strings describe
the same screen.

## Results

| Measurement | Value |
| --- | --- |
| Paired snapshots | 180 |
| Visible captures showing the modal footer (`Enter to select`) | 152 |
| **Reproduced false negatives** (footer visible, glyph absent from visible capture, glyph present in the paired scrollback capture) | **152 of 152** |
| Depth of the real tab bar from the bottom of the scrollback capture | **43 in all 152** (no other value) |
| Visible-capture height | 24 rows (all 180) |
| Scrollback-capture height | 144 rows (all 180) |

Every capture that caught the modal reproduced the defect. There was no passing
sample.

## Real captured pane (verbatim)

The scrollback capture, lines 96–104. Note the order: glyph-bearing **prose**
first (this repo's own text, which the golem had just read), then the **genuine
tab bar**, then the modal body.

Every line carries a `#` gutter (hash plus a space), added here and present in
no capture. Without
it this block would be the one line-initial tab bar in the repo — and since #1010
is precisely what lets Guard 3 read scrollback, a golem reading this file at an
ordinary fork would be misclassified by the matcher this file documents. The
gutter is the smallest edit that keeps the shape readable without arming it.

```text
# ● The capture loop is running. Now I'll raise a genuine two-question form in
#   this very pane — it both settles the real design choice and gathers the live
#   fixture the ACs require.
# ────────────────────────────────────────────────────────────────────────────
# ←  ☐ Capture fix  ☐ Window size  ✔ Submit  →
#
# │ The tab bar is outside the captured pane entirely, so no regex can reach it.
# │ Which capture-side approach should the fix take, given that all nine matchers
# │ share the current flagless capture and widening it re-opens the #246/#452
```

The **visible** capture of the same instant begins mid-option-text and ends at
`Enter to select · Tab/Arrow keys to navigate · Esc to cancel`. It contains no
`☐`, no `☒`, and no `✔ Submit`.

## Two findings this settles

**1. `$pane_error_lines` (40) could not have been reused as the scrollback
depth.** The bar sits at depth **43**, three lines outside it. This was already
the wrong choice on design grounds — it couples two unrelated windows, so a
future change to the API-error read would silently retune form detection — but
the measurement makes it wrong on the numbers too. `GOLEM_PANE_SCROLLBACK_LINES`
defaults to **100**, covering a modal about twice the measured height.

**2. The prose self-trip is concrete, not hypothetical.** The same captured
scrollback carries `☐/☒ … ✔ Submit` prose on lines 41 and 84 — output from this
repo's own verification doc and a `grep` of `MULTI_Q_RE` — directly above the
genuine bar on line 102. Only the bar matches, because `MULTI_Q_RE` is
line-anchored and prose carries the glyphs mid-sentence. One capture therefore
serves as both the positive fixture and the self-trip fixture.

This is why the fix does **not** widen the shared capture. Nine matchers are fed
by it; handing them all scrollback makes every phrase they key on matchable in
arbitrary file content a golem is reading — the #246/#452 class. Guard 3 takes
its own read; Guards 1 and 2 and the eight siblings are fed bytes identical to
before, so their regression evidence is *unchanged input*.

## A/B on the real captured pane

| Input | `pane_is_multi_question_form` |
| --- | --- |
| Visible capture, pre-#1010 code | **1 — missed** |
| Visible capture, no session argument (post-fix fallback path) | **1 — missed**, identical to pre-#1010 |
| Visible capture + session whose scrollback holds the bar | **0 — detected** |
| `pane_is_fork` on the visible capture | 0 — matches, emitting the plain fork label |

The third row is the fix; the second is the fail-open guarantee. The fourth is
the harm: before the fix the operator was told a two-question form was an
ordinary escalation and brokered it with a digit, which is the golem-902
sequence.

## Non-vacuity — every mutation measured

Run against the full `tests/golem-gate-watch.sh` suite (80 assertions, green on
the unmutated tree).

| Mutation | Result | Test that went red |
| --- | --- | --- |
| Guard 3 reverted to the visible-pane scan | rc=1 | `scrolled_off_top`, `scrollback_window`, `scrollback_session` |
| `^` anchors dropped from `MULTI_Q_RE` | rc=1 | `scrolled_off_top_prose` (and the pre-existing #467 prose test) |
| Scrollback depth hardcoded, ignoring the knob | rc=1 | `scrollback_window` |
| Failed capture returns 0 (fabricates a form) | rc=1 | `scrollback_fallback`, `scrollback_window`, `scrollback_session` |
| Unit stub ignores `-t` (cycle 1 follow-up) | rc=1 | `scrollback_session` |
| Knob validation removed (cycle 1 follow-up) | rc=1 | `scrollback_malformed_knob` |
| **Only** the `\| 0` arm of the validation removed (cycle 2) | rc=1 | `scrollback_malformed_knob` |
| `panes_snapshot` forwards a hardcoded session (cycle 2) | rc=1 | `panes_snapshot_multi_session_scrollback` |

Both directions are covered: a mutation that breaks detection turns the positive
test red, and a mutation that loosens detection turns a negative test red.

The anchor mutation is the one worth noting. It turns the **new** scrollback
prose test red *and* the pre-existing #467 visible-pane one — but the two are not
redundant. The #467 fixtures were written when the glyph scan saw only the
visible pane, so they say nothing about prose arriving via the wider read. #1010
is what made scrollback reachable by that scan, and the new test is what pins the
anchoring against it.

## Two vacuous tests caught by mutating, not by reading

Both new tests added in the review cycle passed on first write and were still
worthless. Recording the shape, because a green assertion is the disguise.

**The session test.** The stub parsed `-S` and `-e` but ignored `-t`, so it
served the same canned text whatever session it was asked for. A matcher
forwarding the *wrong* session — a hardcoded literal, an off-by-one in a
multi-session loop — passed every assertion. The stub now owns its text under one
session name and returns nothing for any other.

**The malformed-knob test.** Subtler, and it survived one round of mutation
testing by coincidence. With the knob validation disabled the test still passed,
because the stub **accepted** the malformed `-S --5` argument that real tmux
rejects. The subject under test was the validation; the stub silently made the
thing it guards against harmless. Traced by running the matcher against a stub
that *does* reject a non-numeric depth, which fails as it should — the stub now
models that rejection.

The second one also cost a wrong diagnosis first: an earlier mutation run
appeared to show the test passing because a stale file snapshot had reverted the
validation, making the fix look absent when it was the *test* that was blind.
Restore from git, not from a snapshot taken before the edit you are testing.

## Two vacuous arms the stub concealed — and the shape they share

Cycle 2 returned one **blocking** finding, and it was right: the `0` arm of the
malformed-knob test was vacuous while its three siblings were not. The reason is
worth stating, because it is the same shape twice.

The stub rejected a **non-numeric** depth, which is what real tmux does — so the
`''`/`abc`/`-5` arms genuinely failed when the validation was removed. But `0` is
syntactically valid digits, so the stub served the deep fixture anyway. Real tmux
accepts `-S -0` and returns **only the visible pane** (measured in this image).
Removing just the `| 0` arm therefore reintroduced part of the #1010 miss for a
`GOLEM_PANE_SCROLLBACK_LINES=0` misconfiguration, and every test stayed green.

The same shape had already appeared once: the stub accepted the malformed `-S --5`
argument that tmux rejects. Both times the stub modelled tmux **more permissively
than tmux**, and both times the effect was to make the guard under test
unfalsifiable. A stub is a claim about the real tool; where it is laxer than the
tool, the tests it feeds cannot fail.

Cycle 2 also flagged the **e2e harness had only one session**, so a
`panes_snapshot` regression forwarding a stale, hardcoded, or off-by-one `$sess`
would read the only pane there was and pass. Two sessions is the smallest fixture
that can tell "reads the session it was handed" from "reads the right session" —
mutation M8 confirms it.

## A comment that asserted a safety property the code lacked

Review cycle 2 asked whether the "TWO READS, TWO INSTANTS" comment was *true* of
the code. It was not. The draft claimed the split "can only LOSE a detection,
never invent one." Probed directly — Guards 1–2 passing on a fork's footer while
Guard 3 reads scrollback still holding an **already-answered** form's tab bar —
the matcher labels the fork a form. Nothing ties the bar Guard 3 finds to the
widget that painted the footer Guards 1–2 saw; it is the #467 two-independent-
signals lesson, now reachable from further up the scrollback.

The window is **left open deliberately**, because the two directions are not
symmetric in cost:

| Misread | Operator is routed to | Cost |
| --- | --- | --- |
| fork labelled a **form** (this window) | forward-order, never a digit | a slower gate; the fork still resolves correctly |
| form labelled a **fork** (#1010 itself) | a digit | Q1 answered, Q2 left `☐`, one Enter half-submits |

A false form costs a poll. A false fork costs a decision the golem then acts on.

The left column is checked against the broker protocol, not assumed:
`orchestrate/monitor-protocol.md` § *A multi-question form is brokered
differently* routes a form label to **Path A** — present the questions, then
`↑/↓` + `Enter` per question. Path A drives the same `AskUserQuestion` widget a
single-question fork paints, and the digit the fork broker sends is only a
shortcut for that same selection, so Path A resolves a one-question prompt
correctly. The cost is an extra keystroke and a label implying more questions
than the pane holds.
`test_pane_multi_question_form_stale_bar_in_scrollback` pins the behavior so the
asymmetry is a recorded choice rather than an unnoticed regression, and the
comment now states what the code actually does.

## Repo-wide self-trip re-scan

`MULTI_Q_RE` matched **zero** lines across all tracked files before this change
and **zero** after. The new fixtures build their widget lines through
`printf` argument lists rather than writing them at the start of a source line,
so this test file cannot self-trip the matcher it tests.
