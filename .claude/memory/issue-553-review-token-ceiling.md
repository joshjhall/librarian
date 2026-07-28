---
name: issue-553-review-token-ceiling
description: "#553 — the ship-issue review harness had NO real bound: budget gates are dead code without a runtime turn directive; cost is in-agent exploration, not diff size"
metadata: 
  node_type: memory
  type: project
  originSessionId: b03da476-855a-4340-a1de-499a566aea26
  modified: 2026-07-28T19:57:36.845Z
---

PR #554 (branch `perf/review-token-ceiling`) bounds the ship-issue adversarial
review harness. Two findings worth keeping:

**1. `budget.total` is null in every golem run, so every budget gate in
`workflow.js` was dead code.** The Workflow runtime populates `budget.total`
ONLY from a user `+500k`-style turn directive. No directive ⇒ `total` null ⇒
`remaining()` is `Infinity` ⇒ `BUDGET_FLOOR`/`TAIL_FLOOR` never fire. The
graceful-degradation path (skip dimensions, mark partial, force `clean` false)
never executed. **`budget.spent()` DOES work when `total` is null** — that is
the hook the fix uses to synthesize a per-cycle bound from a baseline captured
at script start (`args.tokenCeiling`, env `REVIEW_TOKEN_CEILING`, default 250k).

Corollary for any future harness: a gate written `if (budget.total && …)` is
inert unless the caller arms it. Check whether the caller actually can.

**2. Review cost is driven by in-agent repo exploration, not diff size.**
Measured on #471/#472 (2026-07-28, 3 cycles): 67.1M cache_read / 2.96M
cache_write / **1.41M output**. Cycle 2 cost 2.6× cycle 1 on the *same* 2-file
diff. Per-agent cycle-2 turns: `security` 254 turns / 115 Bash, `conventions`
139 / 63, `tests` 84 / 35, `bug` 51 / 16, `scope-drift` 18 / 8, `judge` 2 / 0.

This **overturned** my own prior ranking — I had assumed cycles 2-3 were silent
full re-reviews and that #492 narrowing was the top lever. It was not; narrowing
never even engaged. Measure before ranking cost fixes. Also note the operator's
"100-200M tokens" figure is **cache_read** (the ~0.1× tier), not output.

`agent()` has **no turn cap** and there is **no `args.budget`** — I proposed
both before checking, and had to retract. The options are exactly: `label`,
`phase`, `schema`, `model`, `effort`, `isolation`, `agentType`. So exploration
bounds can only be *prompt guidance* (`SCOPE_DISCIPLINE`); the token ceiling is
the only real backstop.

**In-thunk re-check matters.** A caller-supplied ceiling is SOFT — nothing
throws — so checking it only at `parallel()` build time bounds nothing once the
barrier is built. Re-check inside the thunk. (This is the adversarial-review
"budget checked outside the barrier" bug class, self-inflicted then caught.)

Filed but NOT implemented, from the same measurement: #550 (route small/doc-only
diffs around the fan-out), #551 (demote `conventions` — explicitly NOT `tests`,
which owns a blocking judge rule at `workflow.js:552-554`), #552 (mechanize #492
narrowing — PARKED, measurement shows low value).

Related: [[two-runtime-model]], [[workflow-js-no-clock]],
[[token-burn-audit-2026-07-21]], [[issue-492-rereview-narrowing]]
