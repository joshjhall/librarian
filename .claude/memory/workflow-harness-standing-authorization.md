---
name: workflow-harness-standing-authorization
description: "The ship-issue/ci-fixer review harness is standingly authorized whenever a /workflow: pipeline is invoked — run it, don't re-ask each session"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 650f4708-ab7f-40d2-8c31-00b5fd967ad5
  modified: 2026-08-05T14:02:55.576Z
---

When the operator invokes a `/workflow:` pipeline (`golem`, `ship-issue`,
`next-issue`, `orchestrate`), the **Workflow-tool review harness is already
authorized**. Run it directly. Do **not** pause to reconcile it against a
session-level "do not use workflows unless the user requested it" instruction.

**Why:** that session default exists to prevent *unprompted* agent fleets. It
does not cover a pipeline the operator explicitly invoked — `CLAUDE.md` says so
outright. `CLAUDE.md` also says to "say so and ask" before the first review cycle
if you believe a session rule forbids the harness; **this memory is that answer,
given once and standing.** Asking again each session re-litigates a settled
question and costs a round-trip mid-pipeline.

**How to apply:** invoke the harness at `ship-issue/pre-ship-validation.md`
check #6 and `ci-review-protocol.md` step (c) without a confirmation gate. Never
substitute a hand-rolled serial review — measured on PR #642, the harness cycle
is ~5.4 min versus 9–61 min per serial subagent cycle, and the substitute *also*
reports as "a review having run," so the skip never surfaces.

**What this does NOT cover.** The auto-mode **classifier** is a separate
mechanism at the permission layer. It denies `gh pr merge` (and sometimes
`gh pr view`) on a self-authored PR regardless of any workflow authorization —
see [[auto-mode-blocks-self-merge]]. A blocked merge is not a workflow-permission
problem and no harness opt-in changes it; park the PR for a human merge per
[[ship-then-merge-and-prune]].
