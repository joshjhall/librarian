---
name: issue-symbol-inventory-needs-remeasuring
description: An issue's table of duplicated symbols is a snapshot that drifts and counts NAMES, not meanings — re-measure declarations and diff bodies before unifying
metadata:
  type: feedback
---

An issue that proposes deduplicating "the same symbol across N files" ships a
counts table. Treat it as a **dated hypothesis**, not an inventory. Re-measure
before planning, two ways:

1. **Grep the DECLARATION, not the mention.** `grep -c BUDGET_FLOOR` counts
   comments and call sites. `grep '^const BUDGET_FLOOR'` counts declarations.
   A prefix pattern also swallows longer names: on #586, `const READONLY`
   matched `orchestrate`'s `READONLY_POLL` — a *different* symbol with
   different content — inflating the count from 3 to the issue's claimed 4.
2. **Diff the bodies, comments normalized.** Same name ≠ same meaning. Of
   #586's nine candidates, five were semantically divergent (`CERTAINTY_SCHEMA`
   carried an extra severity in one harness; `READONLY` said "review" in one
   and "checker pass" in another). Unifying those would have been a behavior
   change wearing a refactor's clothes. Conversely, two *looked* divergent but
   differed only in a comment or a log noun — a near-miss that a seam unifies.

So the measurement has two outputs, not one: what is genuinely shared, **and**
what is coincidentally same-named. Both belong in the plan, because the second
list is what stops the next reader re-litigating it.

**Why:** the issue's own numbers came from a real measurement — at filing time.
Repos move; #586's table was already stale when the work started, and its
membership question was explicitly deferred to planning, which is the signal
that the filer knew the table was provisional.

**How to apply:** before planning any dedup/extraction issue, re-run the count
against declarations and diff each candidate body with comments stripped. State
the corrections in the plan explicitly — a plan that silently contradicts the
issue reads as sloppiness; one that says "the issue says 4, I measure 3, here is
why" reads as diligence. Related: [[comment-asserts-intent-not-code]],
[[detector-needs-a-certainty-tier]], [[measured-cause-may-invert-the-remedy]].
