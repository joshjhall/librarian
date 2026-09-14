---
name: phantom-prompt-buffer-text
description: "a golem pane's ❯ line may hold an autocomplete SUGGESTION, not queued input; the discriminator is the dim (SGR 2) attribute, a plain capture-pane strips it, and the line is measured inert — Enter cannot submit it"
type: reference
metadata:
  node_type: memory
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-09-13T00:00:00.000Z
---

A golem tmux pane's `❯` input line sometimes shows a plausible next-step
instruction that neither the operator nor the orchestrator typed. It is **Claude
Code's autocomplete suggestion** — inert chrome, not queued input.

**The discriminator is the DIM attribute, and it is measured (#977, 2026-09-09).**
A suggestion is rendered in **SGR 2**; real typed input is not:

```text
suggestion   ESC[39m❯ ESC[2mopen the PR once it lands ESC[0m   (live golem-840)
real input   ESC[39m❯ rebase onto main and push                (control session)
empty        ESC[39m❯
```

Parse the line by anchoring on the composer's **glyph + U+00A0 (NBSP)** prefix,
not the bare glyph: the buffer text can contain the glyph itself, and splitting
on the last bare one drops the opening dim run — silently reporting a real
suggestion as queued input. A selection MENU uses glyph + plain space instead.

**Why it stayed invisible for seven weeks: `tmux capture-pane -p` STRIPS the SGR
run.** Every pane reader used the flagless form, so the one discriminating byte
never reached a matcher. `capture-pane -p -e` preserves it.
`pane_prompt_line_class` in `golem-gate-watch.sh` now takes its own `-e` capture
and the idle lines gain a `· suggestion shown (inert, not queued input)`
suffix. The
shared capture stays flagless deliberately — `-e` in the text the other matchers
read would silently loosen their anchoring.

**`C-u` is evidence, not a mystery.** `C-u` *does* clear real typed input
(measured). Its failure on a phantom is therefore positive confirmation that
nothing is in the buffer — the observation the 2026-07-24 and 2026-09-09 runs
both recorded as an unexplained oddity.

**Observed instances** — 2026-07-24: golem-446 `work the stretch auto-resume
in #465`; golem-494 `merge it once CI is green`. 2026-09-09: golem-793 `file the
upstream report by hand and close #971`; golem-705 `closing 705 was right, move
on to 898`; golem-899 `push it`. Each fired on a golem idle after asking a
question, and each reads as a plausible answer to *that* question.

**Risk: MEASURED INERT (#995, 2026-09-13).** The hazard was framed around a
stray `Enter` submitting one of the outward-facing phantoms (`merge it once CI is
green`; `push it` on a golem that had **explicitly stated** it was withholding
the push). It cannot: `Enter` does **not** submit a suggestion, measured across
two disposable sessions with the transcript — not the pane — as the witness. The
plan-gate broker's `1 Enter` submits the digit `1` and **discards** the
suggestion, because a printable character replaces the ghost text rather than
appending to it. So the broker needs no guard, and the line is cosmetic.

**Inducing one is easy once you know the shape (#995):** run an ordinary turn to
completion, then leave the session idle at an empty composer — 3/3 within ~15s,
with no env var or launch flag. What defeated #977's probe is that a turn ending
in a **selection menu** produces none (it classifies `unknown`, not `suggestion`)
— it idled in that state and concluded the thing would not reproduce.

**Nothing clears the line short of reaping, measured:** `Esc`, `Esc Esc`, `C-u`,
`C-c`, type-then-`BSpace`, type-then-`C-u`, and `Right`-then-`C-u` all leave it
or let it return within a second; submitting a real turn just earns a **new**
suggestion. Typing hides it and `Right` accepts it into the real draft (that is
the accept binding), but clearing the draft re-displays it. Since it is inert,
reaping for disposal is now a cosmetic choice, not a safety one. Full evidence:
`docs/verification/phantom-suggestion-e2e-995.md`.

**How to apply:** (1) Never assume a pane's `❯ <text>` is something you or the
operator queued — check the class, or capture with `-e` and look for the dim run.
(2) **Do not blind-send keystrokes to "clear" it** — not because it is dangerous
(it is inert) but because nothing works; reaping disposes it (golem-705/793).
(3) **Do not escalate it as an intrusion** — the 2026-09-09
session reached "untrusted input channel" on three data points before
checking this file, which had it documented since July. Read the body, not just
the index ([[read-the-memory-body-not-just-the-index]]). (4) A suggestion does
**not** change the liveness verdict: such a golem is still idle.
Relates to [[idle-detector-false-positive-own-monitors]] and
[[orchestrate-broker-then-send]] (only directed digit/Enter sends are compliant).
