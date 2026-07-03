# Next Issue — Mid-flight Escalation Protocol

Companion to `next-issue/SKILL.md`. Load this when, **during implementation or
testing** (after the plan was approved or auto-passed), the working agent reaches
a decision that is **not mechanical** — a genuine architectural or directional
fork, or a wall with more than one viable path forward. This is the **escalation
gate** defined in `orchestrate/autonomy-levels.md` (#174): a judgement call that
is human at **L1–L3** and auto-resolved (the agent picks its recommendation) at
**L4**, except a **dead-end**, which blocks at every level including L4. Resolve
the disposition with
`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh gate escalation --level {N} [--dead-end]`
(→ `disposition=auto|human`, #190) rather than re-deriving the cutoff.

The plan-approval checkpoint is also an escalation gate, but it is handled
structurally in Phase 2 (`EnterPlanMode`/`ExitPlanMode`). This protocol is for
the escalations that surface *mid-flight*, where there is no plan-mode ceremony
to hang them on — the one genuinely new gate in the level model.

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

## Disposition by level

Read the run's level from `autonomy_level` in the state file (see
`autonomy.md` § *Level selection*; legacy `autonomous:true` → L4).

- **L1–L3 — BLOCK and wait for a human.**
  1. Emit the payload to the orchestrate feed classified as an `escalation` (so
     the orchestrator, `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`, and
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-gate-watch.sh` surface it distinctly
     from a routine permission `gate`). The message **must begin `ESCALATION:`**
     so `golem-notify.sh` classifies it — pipe a synthesized Notification
     payload to the hook:

     ```bash
     printf '%s' '{"message":"ESCALATION: <one-line decision> — see issue comment"}' \
       | "${CLAUDE_PLUGIN_ROOT}/hooks/golem-notify.sh"
     ```

  2. Post the full payload (decision + options + recommendation) as an **issue
     comment** for traceability (`gh issue comment {N} --body …` / `glab issue
     note {N} --message …`).
  3. For a **lone `/next-issue`** with no orchestrator, also surface the payload
     **inline** and block the interactive session.
  4. **Wait indefinitely** for the human's choice. The human attaches with
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, picks an option in the
     same session, and the run continues at its level. **Never lapse-and-default
     because the operator stepped away** (see § *Never time out* below).

- **L4 — auto-select the recommendation and continue.** Record the payload (an
  issue comment / run summary for traceability), select the **recommended**
  option, and proceed — **unless it is a dead-end.**

### The dead-end exception (blocks at every level, L4 included)

A **dead-end** is an escalation whose only auto-resolution would violate the
**merge invariant** (never merge unless CI is green *and* review is clean) — no
option is safe, or every path forward would ship an un-green or un-reviewed
change. Per `orchestrate/autonomy-levels.md` and #181, a dead-end **defers to a
human at every level, L4 included**: emit the structured payload (why it is a
dead-end, what was attempted, what options remain) and wait. This is the one
place a fully hands-off L4 run stops.

## Never time out

> Once a gate is raised to a human — at any level that keeps that gate human, and
> at a dead-end regardless of level — **wait indefinitely for the answer.** Never
> lapse-and-default because the operator stepped away. […] A human gate that
> "timed out" and proceeded on a default is a bug, not a level behavior.
> — `orchestrate/autonomy-levels.md` § *Standing rule*

An escalation at L1–L3, and any dead-end, is exactly such a gate. Do not fabricate
a human answer, do not fall back to a default option, and do not treat an absent
operator as approval — hold until a real choice arrives.
