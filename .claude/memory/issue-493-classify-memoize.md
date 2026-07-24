---
name: issue-493-classify-memoize
description: "#493 ci-fixer classify hoist — a naive \"hoist above the loop\" silently changed 2 behaviors (transient-null retry + BUDGET_FLOOR gating); memoize INSIDE the loop instead"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T20:35:18.859Z
---

PR #534 (/next-issue 493 --level 3, feature/issue-493). ci-fixer/workflow.js
classify agent ran once per retry iteration on static `check.logs` → up to MAX-1
redundant classifies/check. Fix = memoize: `let cls = null` above the loop,
`if (needsClassify(cls)) cls = await agent(...)` inside it (9→7 agents worst case).

**Why:** The issue literally proposed "hoist classify above the while loop." My
first cut did exactly that — and the adversarial pre-PR review (cycle 1, 1
blocking scope-drift + correctness/budget deferrables) caught that a full hoist
silently changed TWO behaviors the issue never asked to touch:

1. A null classify short-circuited to `iterations:0` (zero fix attempts) instead
   of retrying via transientVerdict/applyResult. `agent()` is NOT deterministic —
   a null can be a transient parse/schema hiccup, so "deterministic on static
   logs" was wrong reasoning.
2. The hoisted call ran BEFORE the `BUDGET_FLOOR` guard → fired an un-budget-gated
   classify for every check.

**How to apply:** When an issue says "hoist X out of a loop," check what else the
in-loop position gave X: retry semantics, budget/rate gating, unique per-attempt
labels. Prefer **memoize-in-loop** (`if (!memo) memo = await ...`) over a true
hoist when any of those must be preserved — it's the minimal, behavior-equivalent
change. Extract the decision as a pure helper (`needsClassify(cls){return !cls}`,
mirroring `wrapVerify`) so the crux is unit-testable despite the two-runtime
sandbox. Keep the `#${iteration}` label on retried agent() calls (journal/resume
key). AC "behavior equivalent" with no live-fixture path = mark PARTIAL
(code-trace + unit), don't overclaim VERIFIED. Cycle 2 returned clean.
See [[ship-review-diff-must-be-faithful]], [[two-runtime-model]],
[[test-workflow-js-pure-helpers]].
