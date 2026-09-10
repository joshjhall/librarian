# Multi-question form detection — live pane-capture measurement (#986)

**Date:** 2026-09-10
**Session:** `golem-986` (tmux, 24-row pane)
**Why this file exists:** the measurement below cannot be re-derived from a test
run. Every fixture in `tests/gate-watch/` is hand-written text; what is recorded
here is what `tmux capture-pane` *actually returns* for a real Claude Code
`AskUserQuestion` modal. That distinction is the whole finding — a hand-written
fixture produced a **false** conclusion twice during this issue before the live
capture corrected it.

## Method

240 snapshots at 1 s intervals via `tmux capture-pane -p -t golem-986`, taken
while a genuine **two-question** `AskUserQuestion` modal was raised in that
session. 229 of the 240 caught the modal on screen.

The modal was a real one raised by the agent's own `AskUserQuestion` call — not
a mock, not a printed approximation.

## Results

| Measurement | Value |
| --- | --- |
| Snapshots taken | 240 |
| Snapshots showing the modal | 229 |
| Modal captures containing `☐` or `☒` | **0 of 229** |
| Modal captures containing `esc to interrupt` | **0 of 229** |
| Modal captures containing `auto mode on` | **0 of 229** |
| Depth of `Enter to select` from bottom | **−2 in all 229** (no other value) |
| Pane height | 24 rows (all 240) |

## Real captured modal pane (verbatim, `snap-100.txt`)

```text

│ Raising a real modal so the capture loop snapshots an authentic multi-question
│ pane (this is fixture-gathering, not a scope decision). Which chrome variant
│ should I prefer as the canonical fixture if several get captured?

❯ 1. Deepest chrome stack (Recommended)
     Use the capture with the most chrome below the modal footer (e.g. the /btw
     tip hint present). This is the worst case and the one that actually
     reproduces the miss — it pins the boundary rather than a comfortable
     middle.
  2. Minimal chrome stack
     Use the capture with the least chrome below the footer. Represents the
     common case but does NOT reproduce the false negative, so it would pin a
     passing state and prove nothing about the boundary.
  3. Keep both as two fixtures
     Store the shallow and deep captures as separate fixtures — one that passes
     under today's window, one that fails — so the pair brackets the boundary
     explicitly.
  4. Type something.
────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
```

Note what is **absent**: no `☐`/`☒` tab bar, and no bottom status bar. This is a
two-question form.

## Three conclusions, each overturning a plausible hypothesis

**1. A live modal REPLACES the bottom status bar.** `esc to interrupt` and
`auto mode on` are absent in all 229 captures. So `pane_is_multi_question_form`'s
**Guard 1** (the run-spinner veto) never fires on a real modal and cannot be the
cause of a missed form. A fix or fixture premised on Guard 1 vetoing a real modal
is premised on something that does not happen.

**2. Guard 2's 8-line window is not the cause.** `Enter to select` sat at depth
**−2 in every capture** — one chrome line below it, never eight. The arithmetic
boundary is real (8 chrome lines below the footer *would* push it out) but is
**unreachable on a real modal**. An earlier hand-written fixture in this issue
appeared to reproduce a Guard-2 miss; its chrome stack was invented by copying
the *working*-session status bar, which a modal does not paint.

**3. The tab bar is not in the capture at all.** `tmux capture-pane -p` is
invoked with no `-S`, so it returns only the **visible** pane. A two-question
form with real option text is taller than 24 rows, so the `☐/☒ … ✔ Submit` tab
bar scrolls off the **top** and is never captured. Measured: **0 of 229**.

## Regex A/B on the real captured pane

| Regex | Result |
| --- | --- |
| Current `MULTI_Q_RE` | **missed** (`pane_is_multi_question_form` → 1) |
| Narrowed `MULTI_Q_RE` (#986) | **still missed** (→ 1) |
| `pane_is_fork` on the same pane | matches (→ 0), emits the plain fork label |

Both regexes miss, because a glyph that was never captured cannot be matched by
any pattern. `pane_is_fork` matches on the depth-−2 footer, so the operator
receives `escalation — awaiting decision (carries options)` and brokers it with a
digit. That is precisely the golem-902 sequence in the issue.

## What this means for #986 and its follow-up

The regex narrowing in #986 fixes the **false-positive** direction (the
golem-699 single-question pane: old=1 → new=0) and adds a Submit-only arm. It
does **not** fix the false negative, and no change to `MULTI_Q_RE` can.

Note also that **AC 2 as written passes today** — the golem-902 tab bar already
matches the current regex when the bar *is* present. A green AC 2 is therefore
not evidence the false-negative direction is fixed.

The false negative is a **capture-side** defect, tracked as **#1010**. Widening
`pane_error_lines` cannot fix it: that window (40) already exceeds the 24-row
pane. The only fix is capturing scrollback — and that is not a one-line change,
for the reason recorded in #1010: **all nine pane matchers are fed by the same
capture**, so handing them scrollback re-opens the prose self-trip that the line
anchoring and footer anchoring exist to prevent. `golem-gate-watch.sh`'s own
comments already record an earlier proposal to change the shared capture being
rejected on exactly these grounds ("Do not 'fix' this by switching the shared
capture"), with the safer template: take a separate local read and feed only the
matcher that needs it.
