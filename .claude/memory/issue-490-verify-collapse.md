---
name: issue-490-verify-collapse
description: "#490 collapse per-domain fable verify → one O(1) barrier; review caught missing tailAgent wrap on the terminal single-agent stage"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T15:50:31.111Z
---

Issue #490 (L3, PR #519): codebase-audit ran a `fable` adversarial verify **per
domain** (~7-8/audit) → top-tier cost O(domains). Collapsed to **one fable
verify barrier over `allFindings`**, symmetric to the aggregate barrier that
already runs a single checker pass over the same set. O(domains)→O(1).

**Key mechanics:** split the scan→verify `pipeline` into a scan-only fan-out +
one verify barrier placed BEFORE the `allFindings.length===0` clean-report gate
(verify can refute to zero). Extracted `applyVerifyScores(findings, scores)` pure
helper (drop-on-`is_real===false`, keep-unscored, re-score-merge, no-mutate) for
`validate-workflow-helpers.mjs` coverage — the AC3 "equivalent for a fixture
audit" vehicle given the [[two-runtime-model]] (harness can't run offline).
Generalized `verifyPrompt(findings)` — findings carry globally-unique
domain-prefixed refs, so per-domain scoping was cosmetic.

**REVIEW CAUGHT (HIGH, self-inflicted):** my verify barrier was a bare
`await agent()`. As a TERMINAL single-agent stage (runs after all scans, holds
the whole set, priciest tier) it must go through `tailAgent()` — a throw is NOT
caught by pipeline()/parallel() and would kill the run AFTER every scan
completed, discarding all findings instead of failing open. aggregate +
artifact-writer already use tailAgent for exactly this. Fix = wrap + `if
(budgetLow()) budgetExhausted=true` in the null branch (mirror aggregate).
Lesson: any NEW terminal single-agent `agent()` call in a workflow.js harness
needs the tailAgent wrap, not just the fan-out stages.

**Deferred → #516:** single barrier widens cross-domain prompt-injection
blast-radius + removes per-domain fault isolation + unbounded verify payload
(all MEDIUM/LOW; same mitigation family — per-domain fencing / trust-tier /
batching). Cycle-2 review was CLEAN.
