# Next Issue — Mid-flight Escalation Protocol

Companion to `next-issue/SKILL.md`. Load this when, **during implementation or
testing** (after the plan was approved or auto-passed), the working agent reaches
a decision that is **not mechanical** — a genuine architectural or directional
fork, or a wall with more than one viable path forward. This is the **escalation
gate** defined in `orchestrate/autonomy-levels.md` (#174): a judgement call that
is human at **L1–L3** and auto-resolved (the agent picks its recommendation) at
**L4**, except a **dead-end**, which blocks at every level including L4. Resolve
the disposition with
`<skill-base-dir>/../../scripts/autonomy-resolve.sh gate escalation --level {N} [--dead-end]`
(substitute `<skill-base-dir>` per `worktree-safe-recipes.md` — this fires
mid-implementation, inside the worktree, #815)
(→ `disposition=auto|human`, #190) rather than re-deriving the cutoff.

The plan-approval checkpoint is also an escalation gate, but it is handled
structurally in Phase 2 (`EnterPlanMode`/`ExitPlanMode`). This protocol is for
the escalations that surface *mid-flight*, where there is no plan-mode ceremony
to hang them on — the one genuinely new gate in the level model.

**Scope note — the payload and dispatch rules below are NOT mid-flight-only**
(#756). The heading above says *during implementation or testing* because that
was the only such gate when this file was written. A second one now exists
earlier: the **swamp gate** in `plan-sizing.md`, raised during Phase 2 planning
when a decomposition would swamp the issue. It is neither mid-flight nor the
plan-approval checkpoint — `ExitPlanMode` presents a finished plan for approval
and cannot ask "which of these four scopes should this issue have?" before the
plan is written.

Read this file as two layers. The **payload format** and **disposition by
level** (block-and-wait at L1–L3, auto-select at L4, dead-end blocks everywhere,
never lapse-and-default) are the general contract for **every** non-mechanical
gate, whenever it fires. The *mid-flight* framing applies only to **when** the
gates described here arise. A new gate reuses the layers below rather than
inventing a parallel ladder, and says where it fires; `plan-sizing.md` § *The
swamp gate* is the worked example.

## Escalation vs a mechanical decision

Escalate a decision when a reasonable reviewer would want a say **before** it is
committed — because it is directional, hard to reverse, or forecloses a design
the issue left open. Keep going without escalating when the choice is mechanical,
local, or already implied by the plan or the surrounding code.

**Escalate** — examples:

- Two competing architectural approaches with different long-term costs (e.g.
  add a new abstraction layer vs. thread a parameter through existing call
  sites), and the issue did not pick one.
- A directional choice the plan left open (e.g. store the new state in the
  existing state file vs. a new sidecar file; extend an API vs. add a parallel
  one).
- A wall hit during implementation/testing with **more than one viable escape**
  (e.g. the intended library lacks a needed hook — fork it, wrap it, or switch
  libraries), where picking wrong wastes the rest of the work.

**Do not escalate** — examples (proceed, these are mechanical):

- Naming a variable, ordering imports, formatting, or any choice the linters or
  existing conventions already decide.
- A local refactor that preserves behavior and stays inside the plan's scope.
- Picking the one approach the plan already specified, or the only approach the
  surrounding code admits.
- A reversible choice with an obvious default and no downstream lock-in.

**When unsure, escalate.** A false escalation costs a human one glance; a missed
one silently commits an unreviewed architectural decision into a PR. Err toward
raising the gate.

## Escalation payload format

Assemble a compact, self-contained payload so a human (or the L4 self-decision)
has everything needed without re-deriving context:

1. **Decision** — one line stating the fork ("Persist escalation state in the
   existing `next-issue-{N}.json` or a new sidecar file?").
2. **Options** — 2–N options, each a one-line **tradeoff**
   ("A: reuse state file — no new schema, but couples escalation to next-issue
   state"; "B: sidecar — clean separation, but a second file to migrate").
3. **Recommendation** — the agent's recommended option **and a one-line
   rationale** ("Recommend A: the state file already carries the run's autonomy
   context, and the schema is `additionalProperties:false` so the addition is
   explicit").

## Raise ONE question per gate (#467)

When this gate surfaces as an `AskUserQuestion`, ask **one question**. A form
carrying 2+ questions renders as a tabbed widget (`☐`/`☒` per question, a
`✔ Submit` tab), and **no orchestrator broker can resolve it correctly**: the
directed `tmux send-keys` broker assumes a single-question prompt (a digit lands
on the wrong question), and an inbox `answer` carries one option per gate-id
while a form has no single answer. Worse, the widget's review screen offers
`Submit` while questions are still unanswered — so the realistic failure is a
**half-answered form the golem then acts on**, not a visible error.

This is a real cost, not a style preference: a multi-question form forces the
orchestrator onto the cancel-then-text-directive fallback
(`orchestrate/monitor-protocol.md`), which discards the form and re-relays every
decision as prose. So when a gate genuinely has several forks, prefer to **raise
the blocking one first** and let the answer inform the rest, or fold them into
one question whose options are the coherent *combinations*. Reserve a
multi-question form for the case where the decisions are truly independent and
the operator is known to be attached.

## Disposition by level

Read the run's level from `autonomy_level` in the state file (see
`autonomy.md` § *Level selection*; legacy `autonomous:true` → L4).

- **L1–L3 — BLOCK and wait for a human.**
  1. **Mint a gate-id** to correlate this escalation with the operator's
     eventual answer:

     ```bash
     <skill-base-dir>/../../scripts/golem-inbox.sh gateid
     ```

     **Run it bare and READ the printed id** — do not wrap it in
     `GATE_ID="$(…)"`. **The golem minting this gate-id is the isolated one**
     (#815): a solo `/workflow:golem` escalation fires mid-implementation,
     inside the worktree, where a command substitution is refused (#819). Carry
     the printed value forward as `{GATE_ID}` in the three steps below,
     substituting it literally the same way `<skill-base-dir>` is substituted
     (`worktree-safe-recipes.md`, Pattern 1).

     Carry the **same** `{GATE_ID}` through all three of the next steps (the
     feed message, the issue comment, and your own later `consume` call) — one
     id, three carriers, so the orchestrator's answer can never be mis-delivered
     to another golem or another gate (#227).
  2. Emit the payload to the orchestrate feed classified as an `escalation` (so
     the orchestrator, `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`, and
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-gate-watch.sh` surface it distinctly
     from a routine permission `gate`). The message **must begin `ESCALATION:`**
     so `golem-notify.sh` classifies it, and **embed the `{GATE_ID}` in
     brackets** so the orchestrator can parse it off the feed line it already
     reads — pipe a synthesized Notification payload to the hook (substituting
     the id literally, as printed in step 1):

     ```bash
     printf '%s' '{"message":"ESCALATION: [{GATE_ID}] <one-line decision> — see issue comment"}' \
       | <skill-base-dir>/../../hooks/golem-notify.sh
     ```

  3. Post the full payload (decision + options + recommendation) as an **issue
     comment** for traceability, prefixing it with the `{GATE_ID}` so a human
     reading the issue can match it to the feed line (`gh issue comment {N}
     --body …` / `glab issue note {N} --message …`).
  4. For a **lone `/workflow:next-issue`** with no orchestrator, also surface the payload
     **inline** and block the interactive session (there is no orchestrator to
     write the inbox, so this path stays the interactive in-session block —
     brokering augments the orchestrated case, it does not replace the lone
     one).
  5. **Under an orchestrator only — wait indefinitely by polling the inbox.**
     (In the lone `/workflow:next-issue` case of step 4 you have already blocked inline;
     do **not** also enter this loop — there is no orchestrator to write the
     inbox, so it would poll `NO-DECISION` forever.) With an orchestrator, it has
     surfaced this escalation at the top-most session, collected the operator's
     answer once, and writes it to this golem's inbox; consume it to unblock —
     **no `golem-attach` required**:

     ```bash
     # worktree-safe-exempt: ORCHESTRATOR-ONLY path (step 5 gates on "under an
     # orchestrator only"), and an orchestrated golem is launched by
     # golem-launch.sh with `tmux new-session -c`, never EnterWorktree — so it
     # is not isolated and the substitution is not refused here. Unlike the
     # single-shot `gateid` call above, a POLL LOOP cannot use Pattern 1: it must
     # re-read the value each iteration, which is what the substitution is for.
     # Re-invoke on the NO-DECISION sentinel, forever — never default.
     # $GOLEM_ID is stamped into this golem's env at launch (golem-{N}); use it
     # rather than hand-substituting an id.
     ans="NO-DECISION"
     while [ "$ans" = "NO-DECISION" ]; do
       ans="$(<skill-base-dir>/../../scripts/golem-inbox.sh consume "$GOLEM_ID" "$GATE_ID")"
     done
     # $ans is now "DECISION: <option>" (+ optional "NOTE: <text>") — proceed on it.
     ```

     Each `consume` is a **bounded** read (≤`GOLEM_INBOX_WAIT`, default 300s,
     under the Bash-tool ceiling); on no answer it prints `NO-DECISION` and you
     **re-invoke** — so "wait indefinitely" holds as a loop that never gives up
     and **never lapse-and-defaults** (see § *Never time out* below). The
     decision line is `DECISION: <option>` (plus an optional `NOTE: <text>`);
     continue the run on that option at the run's level.

     **`golem-attach` remains the manual fallback** for this gate class: a human
     can still `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}` and pick an
     option in-session at any time — the consume loop simply makes central,
     per-golem-attach-free resolution the common path. Brokering changes *where*
     the human answers, not *whether* one must.

- **L4 — auto-select the recommendation and continue.** Record the payload (an
  issue comment / run summary for traceability), select the **recommended**
  option, and proceed — **unless it is a dead-end.** An L4 escalation resolves
  `disposition=auto`, so it **never mints a gate-id and never calls `consume`**:
  there is no human to broker for, and the golem stays fully hands-off exactly as
  before. The inbox is reached only on the human-gated paths (L1–L3 escalation,
  and any dead-end).

### The dead-end exception (blocks at every level, L4 included)

A **dead-end** is an escalation whose only auto-resolution would violate the
**merge invariant** (never merge unless CI is green *and* review is clean) — no
option is safe, or every path forward would ship an un-green or un-reviewed
change. Per `orchestrate/autonomy-levels.md` and #181, a dead-end **defers to a
human at every level, L4 included**: mint a gate-id, emit the structured payload
(why it is a dead-end, what was attempted, what options remain) with the message
beginning **`DEAD-END:`** and the `[$GATE_ID]` embedded, and then **poll the
inbox with the same consume loop as an L1–L3 escalation** (a dead-end at L4 is a
kept human gate, so it brokers identically). This is the one place a fully
hands-off L4 run stops — and, with brokering, it stops waiting on a *central*
answer rather than a per-golem attach. `golem-attach` remains the fallback here
too.

## Never time out

> Once a gate is raised to a human — at any level that keeps that gate human, and
> at a dead-end regardless of level — **wait indefinitely for the answer.** Never
> lapse-and-default because the operator stepped away. […] A human gate that
> "timed out" and proceeded on a default is a bug, not a level behavior.
> — `orchestrate/autonomy-levels.md` § *Standing rule*

An escalation at L1–L3, and any dead-end, is exactly such a gate. Do not fabricate
a human answer, do not fall back to a default option, and do not treat an absent
operator as approval — hold until a real choice arrives. The inbox `consume`
loop above enforces this mechanically: the bounded read returns `NO-DECISION` on
no answer (never a synthesized option), and you re-invoke it — the wait is an
agent-level loop that never terminates on a default. A single `consume` call
hitting its `GOLEM_INBOX_WAIT` ceiling is **not** a timeout of the gate; it is
one poll window ending, after which you loop again.
