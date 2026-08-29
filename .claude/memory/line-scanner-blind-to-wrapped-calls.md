---
name: line-scanner-blind-to-wrapped-calls
description: A per-line scanner silently misses backslash-wrapped calls — the corpus reads clean because the violations were never parsed
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ce1a1fbd-0733-44ed-9d81-6a516198451e
  modified: 2026-08-28T18:21:24.255Z
---

A scanner that judges one physical line at a time cannot see a call split across
a `\` continuation: the first line carries the function name but no closing
quote for the argument, and the argument's line does not contain the function
name. Neither half matches, so the call is **skipped entirely** and the scan
still exits 0 over a clean-looking corpus.

**Why:** this is the same silent-false-negative class as a GNU-only regex on
BSD, reached by a different route — the gate reports nothing found, which is
indistinguishable from nothing to find. Wrapping is not exotic: it is the
default style for any assertion long enough to need it, so the shapes a scanner
misses are exactly the ones a codebase writes most.

**How to apply:** join continuation lines into one logical line *before*
judging, and report the violation at the line the **call starts on** (keep a
`first_nr`), not where the pattern happened to land. Handle a trailing `buf` in
`END` or a file ending mid-continuation is dropped. Then prove the fix is not
inert by **counting what the scanner can see** before and after — in #830 the
joined scan parsed 98 patterns where the per-line scan parsed 82, so the clean
corpus was genuine rather than 16 assertions being invisible. A fixture in this
repo's own style (`tests/validate-free-port.sh` wraps five calls) belongs in the
test set. Related: [[gnu-host-cannot-mutate-a-gnu-ism]],
[[measure-suppression-before-keeping-it]].
