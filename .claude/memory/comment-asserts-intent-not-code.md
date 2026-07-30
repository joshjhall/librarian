---
name: comment-asserts-intent-not-code
description: "My comments repeatedly assert a property the final code lacks — written from intent, then never re-read against the implementation; reviewers catch it, and the wrong comment hides a real defect"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87b555fb-8e69-4c75-98f3-66c34a760396
  modified: 2026-07-30T09:58:07.683Z
---

Three occurrences across two issues, all caught by review rather than by me:

- **#542 cycle 1** — a comment claimed `sed`/`awk`/`head` were all "load-bearing"
  for the ruff pin. Only `awk` was used. Fixing the comment then broke a test I
  had written that relied on `sed` inside the stub PATH — so the inaccurate
  comment was actively **hiding an unnecessary dependency**.
- **#498 cycle 1** — `plugin_for_skill`'s comment said a lookup miss "degrades the
  message rather than the detection". It did the opposite: `grep` exits 1,
  `pipefail` promotes it, and the bare `plugin="$(...)"` assignment is not
  `set -e`-exempt, so the whole gate died mid-scan. See
  [[set-e-abort-untestable-in-run-test]].
- **#498 cycle 4** — a header described CHANGELOG.md and `docs/verification/**` as
  "exclusions, each asserted below rather than left to the find root". No filter
  existed; they are out of scope by construction. The test would have passed with
  every filter deleted — **false confidence that a guard existed**.

**The mechanism:** I write the comment describing what I *intend*, implement
something subtly narrower, and never re-read the comment against the final code.
The comment then reads as verification that the property holds, which is worse
than no comment — it stops the next reader (including me) from checking.

**What to do:** after finishing a function, re-read its comment as a *claim to be
falsified*, not a summary. For each load-bearing assertion, name the line that
makes it true. If you can't, either fix the code or delete the claim. Prefer
comments that state the failure mode and why the guard prevents it ("without
`|| true` the miss aborts the gate mid-scan") over ones that state an outcome
("degrades gracefully") — the former is checkable, the latter is a wish.

Two adjacent vacuity traps from the same issue: a "no active filter" claim whose
test passes by construction (pin the *property it depends on* instead — e.g.
assert the corpus root stayed narrow), and a uniqueness check reading a `sort -u`'d
variable that has already collapsed the collision it looks for.
