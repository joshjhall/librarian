---
name: workflow-js-no-clock
description: workflow.js harnesses cannot self-bound in wall-time (no clock/timer in sandbox); bound at the caller
metadata: 
  node_type: memory
  type: project
  originSessionId: 248f0b25-834a-42e3-91b6-a7001ce6492a
---

The `workflow.js` sandbox bans clocks and timers so per-step resume stays
deterministic: `Date.now()`, `new Date()`, `Math.random()` all **throw**; there
is no `setTimeout`, `Promise.race`-timer, or `AbortSignal`, and `agent()` has no
per-agent timeout option. A *spinning* subagent emits no tokens, so it never
advances `budget.spent()` either — the token budget bounds cost, not latency.

**Consequence:** a harness cannot deadline itself, and there is no `timed_out`
flag it can ever set (that would be dead code). A wall-clock bound MUST live in
the **caller** — the Claude turn that invokes the `Workflow` tool: background
invoke → poll `TaskOutput` against a threshold → `TaskStop` → recover partials
from `<transcriptDir>/journal.jsonl`.

Shipped in #224 (PR #307): `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (20m) +
`_MAX_EXTENSIONS` (1) + `plugins/workflow/scripts/recover-journal-partials.sh`,
wired into ship-issue's review/ci-fixer callers, guidance in
`dev-core:workflow-authoring` § "No Clock in the Sandbox". #306 (PR #334)
extended the same bound to codebase-audit (`review-audit`) + orchestrate
(`workflow`) callers. Two non-obvious details from #306: (1) only
subagent-fanning modes need the bound — orchestrate `pool`/`tracks` are
pure-compute (never call `agent()`), so they're **explicitly exempt**; and
recovery for `poll`/`poll+rebase`/`train` is checkpoint-resume/re-run, **not**
`recover-journal-partials.sh` (those modes emit `pr_status[]`/train-graph state,
not finding-shaped partials the script's fingerprint matches). (2) codebase-audit
is in `review-audit` but the recover script ships in `workflow`, so its
`${CLAUDE_PLUGIN_ROOT}` can't reach it — derive the sibling path by
segment-swapping the plugin name (`sed 's#/review-audit/#/workflow/#'`; versions
are lockstep per `bin/release.sh`) with graceful degradation. Sibling of
[[workflow-js-no-module-system]] — another "the sandbox can't do X, stop
re-proposing it" constraint.

**Why:** future audits/authors keep proposing an in-harness timer; it is
impossible on this runtime.
**How to apply:** when a harness needs a latency bound, wire it at the caller
with the existing env vars + helper, never inside `workflow.js`.
