---
name: strictness-first-fails-in-the-checker
description: When a gate gets stricter, its first failures are usually defects in the gate's own parser — diagnose before touching the subject
metadata:
  type: feedback
---

Making a gate finer-grained (per-row → per-cell, per-file → per-region) will
produce failures on a tree that was already correct. The reflex is to "fix" the
subject so the gate goes green. **Diagnose each finding first: at this stage most
of them are bugs in the newly-strict parser, not in what it checks.**

**Why:** narrowing #847's language-table gate to per-cell produced three real
failures against an unchanged, correct tree, and all three were mine:

- bash function scope was never closed at a top-level `}`, so a top-level `case`
  block was attributed to the previous function and its `go` arm contradicted a
  correct `—` cell;
- a cell's parenthetical narrowing (`M (js/jsx only)`) had been *prose* under a
  row-level check — there was no per-cell state for it to qualify — so demanding
  arms for the whole row was wrong;
- markdown rows were split on a bare `|`, shattering a cell containing
  `export function\|class\|…` and shifting every later column. Invisible while
  rows were OR-ed together; load-bearing the moment cells must align.

Editing a scanner or a contract matrix to satisfy any of those would have
recorded a defect that did not exist and hidden a broken parser.

**How to apply:** for each new failure, ask "would this have been a finding
before?" and reproduce the specific extraction by hand before changing anything
outside the gate. State up front — in the plan — that a surfaced cell is a
*finding to report*, not a matrix to edit, so the pressure to go green does not
quietly redefine the subject. A finer gate also makes previously-decorative
prose enforceable; check what silently changed meaning. Related:
[[comment-asserts-intent-not-code]], [[pinned-behavior-may-be-a-bug-report]].
