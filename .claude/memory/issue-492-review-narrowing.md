---
name: issue-492-review-narrowing
description: "#492 ship-issue re-review narrowing — PR #528; skill passes delta args, harness narrows delta-local dims; prior-blocking MUST re-confirm on FULL diff"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T20:35:13.691Z
---

**#492** — PR **#528** (L3, `feature/issue-492`): `ship-issue` re-review cycles
were re-scanning the WHOLE PR diff every cycle (worst case 3× at maxCycles=3).
Fix = skill computes the fix-commit delta (`deltaDiff`/`deltaFiles` +
`priorBlockingDimensions`) each cycle and passes them in `args`; harness narrows.
The `workflow.js` sandbox has no git ([[two-runtime-model]]) so narrowing is
**skill-driven, harness-applied** — same pattern as `cycle`/`prComments`.

**Load-bearing design rule (a review-caught bug, NOT in the original plan):** the
diff a re-run reads depends on WHY it was included —

- included because the delta **touches** its file types → reads the **delta** (the saving);
- included via the **prior-blocking carry-over** → reads the **FULL diff**, because
  the finding it must re-confirm may live OUTSIDE the fix delta. Feeding it only the
  delta blinds it → the still-unresolved finding silently vanishes from `blocking`
  → false `clean` → merge-safety hole. `diffForInclusion(narrowed,touches,prior,...)`.
- `scope-drift` ALWAYS full diff (whole-change AC-completeness lens; Fork A, operator-confirmed).
- Narrowing NEVER sets `budget_exhausted`/`dimensions_skipped` (a delta-irrelevant
  drop is complete-by-design, not partial) — else every narrowed cycle forces `clean:false`.
- New args OPTIONAL + default-off ⇒ cycle 1 byte-identical.

**LESSON — dogfooding the review harness on its own change is high-value.** Ran the
pre-PR review 3 cycles USING the narrowing feature: cycle1 caught the specialist
AC#3 gap, cycle2 caught the prior-blocking-reads-only-delta merge-safety bug +
config-type coverage gap (both self-inflicted, neither in the plan), cycle3 clean.
The narrowing itself worked (correctly excluded the unchanged `pre-ship-validation.md`).

Deferred follow-ups: #529 (security dim on ci/docker-only deltas), #530 (reviewer
file-header vs full-diff scope), #531 (#503 baseline refresh). Pure helpers
(narrowingActive/selectReviewDimensions/includeSpecialist/diffForInclusion) live
above the ORCH boundary + unit-tested in validate-workflow-helpers.mjs
([[test-workflow-js-pure-helpers]]). Hit [[edits-landed-in-main-not-worktree]]
guard once — use the `.worktrees/issue-492/` path. #503 bloat now stale (821→~1082).
