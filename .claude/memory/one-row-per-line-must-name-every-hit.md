---
name: one-row-per-line-must-name-every-hit
description: Collapsing N findings into one row re-creates the suppression bug unless the evidence enumerates every hit
metadata:
  type: feedback
---

When a scanner emits **one row per line** but a line can carry several real
findings, the evidence field must **enumerate every one**. Naming only the first
re-creates, in miniature, the very suppression such a fix usually exists to
remove: the line is flagged, so the row looks handled, while the second finding
is invisible.

**Why:** #860's TSV is keyed `file/line/category`, so two rows for one line would
share a key — one row per line was right. But `evidence` is the *truncated line*,
and at the 80-char cap a later secret's name is **cut off the line entirely**. So
the key list (`Possible hardcoded credential (api_key, auth_token): …`) is the
only thing that keeps the second secret visible to a reader. The same logic says
repeats are **not** deduped: `(api_key, api_key)` reports two real occurrences,
and collapsing them would hide one.

**How to apply:** When choosing row multiplicity, ask what the evidence field
actually contains. If it is the whole line, extra rows are duplicates and one row
is correct — but then make the row name every hit. Pin it with a test that
asserts the **second** hit's identifier appears in the evidence: a test asserting
only "exactly one row" passes while the second finding is silently dropped, so it
cannot catch this. Mutate by emitting just the first name — only the evidence
assertion should redden, while the row-count assertion stays green.

Related: [[absence-assertion-needs-a-leak-fixture]],
[[fixture-must-express-the-divergent-case]], [[blocking-empty-is-not-nothing-to-fix]].
