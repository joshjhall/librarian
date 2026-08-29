---
name: prefix-match-is-not-an-exact-pin
description: "An index()==1 / startswith check pins a PREFIX, so a superset value satisfies it and the assertion decays to a presence check"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ce1a1fbd-0733-44ed-9d81-6a516198451e
  modified: 2026-08-28T18:21:35.070Z
---

`index(line, needle) == 1` (or any startswith) anchors only the **left** side. A
value pin built on it accepts every superset: `SKIP_EXIT_CODE=770` satisfies a
pin of `=77`, and `... || exit 10` satisfies `... || exit 1`. The assertion
quietly becomes the presence check it was written to replace.

**Why:** the left anchor feels like the whole fix because it solves the visible
problem (matching mid-line or in a comment), so the missing right boundary reads
as done. Test choice then hides it — comparing `77` against `99` passes with and
without a boundary, because the two share no prefix. Only a value that *extends*
the pinned one separates the two implementations.

**How to apply:** when a match must be exact, anchor **both** ends — require the
line to end at the needle, tolerating only what is invisible to the value
(trailing whitespace, a `\` continuation). Write the fixture as the superset,
never a disjoint value; that is the [[fixture-must-express-the-divergent-case]]
rule applied to string matching. And check the failure text with it: a
right-boundary miss reports "no such definition" directly above a live
definition whose value merely drifted, which sends the reader after the wrong
cause — name value-drift and commented-out separately. Related:
[[anchored-regex-tautological-test]], [[config-prose-satisfies-its-own-assertion]].
