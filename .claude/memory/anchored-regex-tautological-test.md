---
name: anchored-regex-tautological-test
description: "A suppression test whose fixture never matched the detector's anchor passes with AND without the fix — tamper-check every negative assertion"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 09a9b961-83e6-4097-bdba-73cbf06daca6
  modified: 2026-07-30T22:09:34.501Z
---

When testing that a detector **stops** flagging something, the fixture must first
be a line the detector would actually have flagged. On #599 the debug-statement
suppression test used an indented `command grep -nE -- '^\s*console\.(log)\('`
line — but the debug arms are anchored `^\s*console\.` / `^\s*print\(`, so an
indented grep line never matched them in the first place. The test passed
**before and after** the fix while asserting nothing.

The reachable shape was different: a line that *emits* a pattern literal
(`console.log("grep -nE -- '^\s*console\.(log)\('")`), at line start, where the
anchor genuinely fires.

**Sequel (#604) — the reshaped fixture proved the FIX was wrong, not just the
test.** That line-start shape is not a scanner self-match at all: it is a
genuine debug statement whose *argument* looks like a regex. Reshaping the
fixture to reach the guard was fixing the test to match the code
([[comment-asserts-intent-not-code]]) instead of asking whether the guard should
exist. It shouldn't have: the debug arms are anchored, so a real scanner's
literal — always indented inside a grep call — can never self-match, and
measurement showed the guard suppressed **0 rows** across every scanner in the
tree while causing a false negative. When a fixture cannot reach a guard, ask
*whether anything real ever reaches it* before reshaping the fixture until it
does. Measure the suppression's actual yield — neuter the predicate, diff the
output — rather than assuming the guard earns its place.

**Why:** a green negative assertion is indistinguishable from a vacuous one. This
is the same failure mode as [[blocking-empty-is-not-nothing-to-fix]] and
[[collect-all-test-assertions-must-not-throw]] — the test reports success while
covering nothing.

**How to apply:** for every "X is no longer flagged" test, revert ONLY the
scanner (keep the tests) and confirm the case FAILS. `git stash` is the wrong
tool — it reverts the tests too, so everything silently passes. Use
`cp <file> /tmp/keep && git checkout -- <file>` then restore. Also pin both
halves from ONE fixture (suppressed line + genuine finding in the same file), so
a blanket path-based exemption cannot pass the test. See
[[comment-asserts-intent-not-code]].
