---
name: phantom-prompt-buffer-text
description: "a golem pane's ❯ line may hold an autocomplete SUGGESTION, not queued input; the discriminator is the dim (SGR 2) attribute, and a plain capture-pane strips it"
metadata:
  node_type: memory
  type: reference
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-09-09T00:00:00.000Z
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

**Risk: benign while inert, but treat it as a latent hazard.** The buffer submits
only on `Enter`, which nothing sends — but the plan-gate broker sends `1 Enter`
into these very panes routinely, and two of the five phantoms were outward or
gate-bypassing (`merge it once CI is green`; `push it` on a golem that had
**explicitly stated** it was withholding the push pending its portability gate
and review cycle 2). A stray `Enter` would submit an unapproved action.

**Still unverified (#977 could not settle these):** whether `Enter` can submit a
suggestion, and whether anything clears the line short of reaping. A disposable
probe session would not reproduce a suggestion on demand across ~10 minutes, so
both are recorded as open rather than guessed. Until they are answered, keep
treating a phantom line as a latent hazard and reap rather than clear.

**How to apply:** (1) Never assume a pane's `❯ <text>` is something you or the
operator queued — check the class, or capture with `-e` and look for the dim run.
(2) **Do not blind-send keystrokes to "clear" it**; reaping the session disposes
it (confirmed on golem-705/793). (3) **Do not escalate it as an intrusion** — the
2026-09-09 session reached "untrusted input channel" on three data points before
checking this file, which had it documented since July. Read the body, not just
the index ([[read-the-memory-body-not-just-the-index]]). (4) A suggestion does
**not** change the liveness verdict: such a golem is still idle.
Relates to [[idle-detector-false-positive-own-monitors]] and
[[orchestrate-broker-then-send]] (only directed digit/Enter sends are compliant).
