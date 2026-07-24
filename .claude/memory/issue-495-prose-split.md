---
name: issue-495-prose-split
description: "#495 SHIPPED PR #527 (L3, parked for human merge — auto-mode blocked self-merge); split always-loaded workflow prose to on-demand dependency-queue.md + dedup standing-rules; the #409 handoff guard greps SKILL.md for literal \"before ... plan mode\""
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T20:35:44.537Z
---

Issue #495 (`type/refactor`, `effort/large`, `severity/low`) — SHIPPED PR #527 at L3,
**parked for human merge** ([[auto-mode-blocks-self-merge]]: `gh pr merge` on a
self-authored L3 PR denied by the auto-mode classifier even with green CI + clean
review; NOT a dead-end — the merge invariant was satisfied).

**What:** shrink always-loaded `workflow` skill prose.

- Split the ~258-line blocked-by/dependency-queue algorithm out of the
  always-loaded `next-issue/state-format.md` (710→498) into a new **on-demand**
  `next-issue/dependency-queue.md`; kept `## Blocked-by Exclusion` / `## Dependency
  Queue` **stub headings** so top-level `state-format.md §` refs still resolve.
- Deduped standing-rules to their existing authority sites: never-time-out →
  `autonomy-levels.md § Standing rule`; golems-are-processes → `ship-protocol.md
  § Golem Execution Model`. Collapsed full restatements in the 3 SKILL.md +
  mode-protocol.md to one sentence + pointer.
- Moved ship state-reconstruction to `ship-protocol.md`; collapsed orchestrate
  Phase-D plan-gate prose (dup of `mode-protocol.md § Plan gate by level`).

**Two reusable gotchas:**

1. **`validate-next-issue-handoff.sh` greps `next-issue/SKILL.md` for the LITERAL
   line-local regex `before .*(EnterPlanMode|plan mode)` (#409 guard).** My prose
   collapse first dropped the word "before" (wrote "entering it earlier"), then
   put `before` and `EnterPlanMode` on the same line but as `**before**` (no
   trailing space) — the regex needs `before` + a SPACE. Rephrase kept
   "must all complete before `EnterPlanMode` is called". Re-run that test after
   ANY edit to the plan-mode-ordering prose.
2. **Reference sweep must catch deep cites, not just section headings.** The
   adversarial pre-PR review (clean, 0 blocking) caught a stale `state-format.md`
   ref at `SKILL.md:244` (the cycle `ERROR:` line moved to dependency-queue.md)
   that my heading-level sweep missed; a sibling was in `pool-train-protocol.md`.
   Grep for cited CONTENT (cycle/ERROR/algorithm/blocked-by detection), not just
   `state-format.md §`.

Sequenced before #503 (large-file decompose). SKILL.md still >300 WARN (419/436/325)
but under 500 HIGH — AC said "toward/under", directional progress accepted.
