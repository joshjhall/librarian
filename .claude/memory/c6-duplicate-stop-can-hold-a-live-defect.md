---
name: c6-duplicate-stop-can-hold-a-live-defect
description: review-convergence.sh returning stop/C6-duplicate is not a merge signal when the cycle also found a BLOCKING defect — the fix that follows is unreviewed
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fd8cc9b2-f617-4a90-85a4-cb585f9fe968
  modified: 2026-08-16T18:19:19.095Z
---

`review-convergence.sh check` can return `verdict=stop rule=C6-duplicate` on a
cycle that **also returned a blocking finding**. Reading that `stop` as "the
review is done" merges a fix that no cycle ever looked at.

Seen on PR #702 (issue #613), twice in one run:

- Cycle 2 — `stop`/`C6-duplicate`, and one HIGH blocking defect (a stated `R8`
  count of "four" against a table summing to five).
- Cycle 3 — `stop`/`C6-duplicate` again, and **three** dimensions independently
  flagging the same leftover stale count in another paragraph.

Both were real and both were fixed. Cycle 4 — a full comparable surface with no
fix pending — returned zero findings and `C4-zero` / `zero-comparable-surface`
with `capped_over` empty. That is the signal worth merging on.

**Why it happens:** `C6` compares this cycle's findings against the previous
cycle's by position/ref, so a *second* finding in a region already flagged reads
as a duplicate even when its content is new. The rule is about reviewer
repetition, not about whether the code is clean.

**How to apply:** the stop verdict is necessary, not sufficient. Before merging,
check the composition the way the merge invariant does — `stop` **plus**
`clean: true` **plus** no fix committed after the last cycle that produced it.
If the cycle that said `stop` also found something you then fixed, run one more
full cycle; a `stop` whose `capped_over` is non-empty gets the same treatment
(see the uncapped re-run trick). This is the predicate-side sibling of
[[blocking-empty-is-not-nothing-to-fix]] — same failure shape, different
gatekeeper: a healthy-looking verdict over an unreviewed change.
