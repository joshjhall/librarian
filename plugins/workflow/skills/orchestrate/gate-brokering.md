# Orchestrate — Gate Brokering

Companion to `orchestrate/monitor-protocol.md`, split out of it in #973 when that
file passed its prose budget. Monitoring answers *what is each golem doing*;
brokering answers *how does a human answer a golem that is blocked*. They meet at
one point — the gate line the monitor surfaces — and are otherwise separate jobs,
which is the seam.

This file carries the whole brokering surface: central inbox resolution for
escalations and dead-ends (#227), the directed `tmux send-keys` broker for
plan-gates, multi-question forms (Path A / Path B), the pane-reading rules, and
the **data-only invariant** that keeps a plan-gate off the inbox path.

Load it when a golem is BLOCKED and you are answering it. For the sweep itself,
stay in `monitor-protocol.md`.

**Resolve a brokered gate centrally (the inbox — #227).** For an **escalation**
or **dead-end** line (not a routine permission `gate`, and not a plan-gate — see
the data-only invariant below), you can relay the decision back into the golem
from **this** session instead of `golem-attach`'ing into its TTY:

1. **Parse the gate-id.** The golem embeds a `[gate-<epoch>-<rand>]` token in its
   `ESCALATION:`/`DEAD-END:` message, so the emitted `golem-{N}\t<message>` line
   already carries it. Extract it:

   ```bash
   gate_id="$(printf '%s' "$message" | command grep -oE 'gate-[0-9]+-[0-9a-z]+' | command head -n1)"
   ```

2. **Present the payload once, centrally.** Read the full decision payload
   (decision + options + recommendation) from the golem's **issue comment**
   (posted at escalation time, prefixed with the same gate-id) and present it to
   the operator via **one** `AskUserQuestion` — the options are the escalation's
   own options, plus a *"let me attach instead"* escape hatch.

3. **Relay the answer down.** On the operator's choice, write it to the golem's
   inbox:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/golem-inbox.sh" answer "golem-{N}" "$gate_id" "<chosen-option>" \
     [--note "<optional one-liner>"]
   ```

   The golem's `consume` loop reads it and proceeds — **no attach required**.
   Attribution is two-layer (inbox filename keyed by golem-id + in-record `gate`
   filter), so the answer can never reach the wrong golem or the wrong gate.

**Auto-relay across many golems.** Because the feed `--stream` above emits one
line per *fresh* escalation, the natural monitor loop is: on each emitted
`escalation`/`dead-end` line, run steps 1–3 — present via `AskUserQuestion`,
`answer` into the inbox — then return to the stream. One operator supervising N
golems thus **batch-answers** each blocked golem from this session in turn,
never hopping between N TTYs. `golem-attach.sh {N}` stays available as the manual
fallback for any gate the operator would rather handle in-session.

**See which gates are still unanswered (#395).** `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`
annotates each escalation/dead-end line in its BLOCKED list with the inbox state
— `[inbox: awaiting]` (no decision written yet), `[inbox: answered]` (a decision
is waiting for the golem to consume), or `[inbox: consumed]` (the golem has taken
it). Read this before answering: an `awaiting` line still needs a decision, while
an `answered`/`consumed` one is already handled — so an operator sweeping a batch
does not **double-answer** a gate the golem hasn't consumed yet. The annotation
is a read-only snapshot (`golem-inbox.sh state <golem> <gate-id>`), point-in-time
like the rest of the status view; a routine permission `gate` or plan-gate
carries no gate-id and is left un-annotated (it is not inbox-brokered — the
data-only invariant below).

**A multi-question form is brokered differently — different keystrokes, or
cancel and relay as text (#467).** When the gate-watch line reads *"escalation
(multi-question form) — forward-order only, never a digit"*, the golem raised
**2+ questions in one `AskUserQuestion`**, rendered as a tabbed widget (`☐`/`☒`
per question, a `✔ Submit` tab). **Neither broker above applies as written**: the
`send-keys 1 Enter` recipe assumes a single-question prompt (a digit does nothing
here, or hits the wrong question), and an inbox `answer` carries one option per
gate-id while a form has no single answer. Both fail by **resolving the gate
wrong** rather than visibly failing — so use one of the two paths below instead.

**Step 1 is the same either way — present all N questions** via **one**
`AskUserQuestion` in this session (the same central-resolution shape as the
numbered steps above). How you commit the answers has two paths, and the
**forward-order keystroke path is preferred** because it submits the whole
answer vector atomically and keeps the golem's own form intact:

**Path A — forward-order answer + submit (preferred).** Verified live on a
two-question plan-time form (golem-16), both answers recorded correctly:

1. Land on question 1 (the widget opens on it).
2. `↑/↓` to the desired option, `Enter` to select. The widget **auto-advances to
   the next unanswered question** (`☒` appears on the one just answered).
3. Repeat `↑/↓` + `Enter` for each subsequent question **in the order presented**.
4. After the last one the widget lands on the `Submit answers / Cancel` review
   screen with **every** question `☒`. `Enter` on "Submit answers" commits the
   vector atomically.

> **Never navigate backward.** Answer in the widget's own order, let it
> auto-advance, and submit only once every question shows `☒`.

**Path B — cancel-then-text-directive (fallback).** Use it whenever Path A does
not apply: you need to **revise an earlier answer**, answers were taken out of
order, or the widget is in any state you did not drive from question 1. Select
`Cancel` on the review screen — the golem logs "User declined to answer
questions" and drops back to its prompt with nothing submitted — then **relay
every decision as one plain-text directive** naming each choice ("Both
decisions: (1) Commit-back = Auto-MR … (2) Frontmatter = Surgical …"). Proven
across three live incidents (2026-07-21 golem-13, and two more brokering #816
and #793).

**Never send a text directive as one `send-keys` call (#974).** The obvious
spelling is wrong:

```bash
# WRONG — the directive lands in the composer UNSUBMITTED.
tmux send-keys -t golem-{N} "OPERATOR DIRECTIVE: ..." Enter
```

Combined, the payload and the trailing CR arrive in the **same** `read()`, and
the composer treats a CR inside one input chunk as a newline *within* the
message rather than a submit. The text sits in the prompt, `tmux` reports
success, and the golem idles until a **second** `Enter`. This is not
length-dependent (measured at 200 chars) and has nothing to do with
bracketed-paste. Use the helper, which splits the payload from the submit and
confirms the composer emptied:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/golem-mode-check.sh verify-text {N} "OPERATOR DIRECTIVE: ..."
```

Quote the whole directive as **one** argument, and keep the payload
**operator-authored** — `-l` stops tmux resolving it as key names, but it does
not strip terminal escapes, and the text is painted into a pane a human later
reads over `golem-attach.sh`. Relay a summary you wrote, never an untrusted
issue or comment body piped straight through. **`verify-send` does not cover
this** — its predicate asks only whether the pane *changed*, and typed-but-
unsubmitted text changes it, so it reports `send confirmed` on exactly this
failure. Two refusals to read correctly, because they call for opposite moves:
`NOT SUBMITTED` means the text **was** typed and is sitting unsent — attach and
press Enter, do **not** re-send the payload (it would double). `NOT SENT` means
the composer already held text so nothing was typed at all — attach, clear the
prompt, then retry.

**What actually breaks — the constraints both paths are built on.** Backward
navigation is the move that fails, not keystrokes in general:

- **Digit-select does not work** in this widget. A sent digit did nothing in one
  incident and **landed on the wrong question** in another; it needs `↑/↓` +
  `Enter`, unlike the single-question prompt where `1`+`Enter` selects. **So a
  broker must branch on single-vs-multi question** — which is what the distinct
  gate-watch label above is for.
- **`Tab` does not reliably reach an unanswered question.** After answering Q2
  first, `Tab` cycled between the *answered* question and the Submit/review
  screen — never onto the still-`☐` Q1, despite the tab bar implying it would.
  This is why Path A insists on forward order.
- **The review screen offers `Submit` while questions are unanswered** ("⚠ You
  have not answered all questions"). One stray Enter submits a **half-answered
  form**, and the golem acts on it as a decision the operator never made. Path A
  avoids this by construction (submit only at all-`☒`); Path B avoids it by not
  submitting at all.

**Read the pane, not just the footer.** On #816 the first `capture-pane` showed
only **one** of the form's **two** questions — the tab bar had scrolled above the
footer — so the form looked like an ordinary single-question fork. That is why
the gate-watch matcher scans a wider window than the footer, and why the
distinct label above is what you should trust over your own read of the pane.

**The data-only invariant is untouched by either path.** Path A's selections and
Path B's cancel are **directed keystrokes** carrying no auto-mode transition, and
Path B's relay is plain text — none of it is an inbox `answer`, and a plan-time
form is not inbox-routed. A form raised at the **plan gate** is still resolved
the way every plan-gate is: the human decides, the orchestrator sends. See below.

**Data-only invariant — do NOT broker a plan-gate this way.** A plan-gate
`ExitPlanMode` (feed: a generic `gate`; pane: the plan-approval overlay) resolves
an **auto-mode** transition, which the inbox must never carry. Plan approval
stays on the compliant directed `tmux send-keys` broker (`SKILL.md` § Phase D and
`mode-protocol.md` § *Plan gate by level*, settled in #281): present the plan,
and on approval **the orchestrator sends the keystroke**, a human-authorized
directed action — never an inbox `answer`. The inbox is for escalation/dead-end
**data** only. See `mode-protocol.md` § *Reverse channel (the inbox)* for the
full #29 rationale.
