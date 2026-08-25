---
name: render-diff-before-and-after-an-extraction
description: A behavior-preserving refactor should be proven by diffing the tool's real output before vs after, not only by a green suite
metadata:
  type: feedback
---

When a refactor claims "no behavior change," capture the tool's **actual output**
before and after against one seeded sandbox and `diff` the two. Keep a copy of
the pre-change script (`cp`, or `git show origin/main:<path>`) so both versions
can run side by side, and normalize genuinely time-varying fields
(`sed -E 's/[0-9]+s ago/N ago/'`) rather than eyeballing past them.

**Why:** the existing suite asserts the things someone thought to assert. On #800
it never compared two *whole* renders, so section ORDER, blank-line placement,
and the exact wording between asserted substrings were all unpinned — precisely
what an extraction that moves inline blocks into functions is most likely to
disturb. The diff covers every byte no assertion happens to name, and it takes
about a minute.

Run it for **each** output mode the tool has (`golem-status.sh` needed both the
verbose and the `--checkpoint` render) — a refactor can preserve one path and
disturb the other, and only the mode you actually captured is evidence.

**How to apply:** build the sandbox once, capture BEFORE, apply the change,
capture AFTER, diff. If the only differences are wall-clock, say exactly that in
the PR rather than claiming an unqualified "identical". Complements
[[split-verify-proves-the-split]]: that proves no content was lost, this proves
no behavior moved.
