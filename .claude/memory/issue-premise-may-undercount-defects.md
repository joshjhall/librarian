---
name: issue-premise-may-undercount-defects
description: An issue naming ONE cause may hide two; reproduce the issue's OWN example and check whether the named cause explains its silence
metadata:
  type: feedback
---

An issue that names a single root cause can be describing **two independent**
defects. Reproduce the issue's **own headline example** and ask whether the named
cause actually explains it — if a fix for the stated cause leaves that example
broken, the diagnosis is incomplete, not merely imprecise.

**Why:** #860 filed "first-match-only" — a placeholder credential suppressing a
real one sharing its line. That defect was real. But the issue's own repro,
`{"password": "changeme", "api_key": "realsecret"}`, was silent for a *different*
reason: the regex required the key be followed immediately by whitespace/`=`/`:`,
so a **quoted** JSON key never matched at all. Proof it was independent:
`{"api_key": "realsecret"}` — **no placeholder anywhere** — was also silent, so
the placeholder logic could not be the cause. Implementing only the issue's
"Work" section (`re.finditer`, drop `head -n 1`) would have shipped green tests
with the issue's stated example still broken, and AC1 unmet.

**How to apply:** Before implementing, run the issue's literal repro against the
current code. Then isolate: construct the variant that removes the named cause
(here, delete the placeholder) and see if it still fails. If it does, there is a
second defect. Fix both, and **correct the issue body** with the measurement as
evidence, rather than leaving a diagnosis the code disproves. Widening the fix
needs its own safety evidence — A/B the change over the whole repo corpus and
report the row delta (here: 59 rows before, 59 after, zero new).

Related: [[issue-cause-may-be-falsified-by-measurement]] (the A/B that shows a
no-op fix), [[parity-gate-hides-shared-defect]] (why both runtimes agreed on the
bug), [[fixture-must-express-the-divergent-case]].
