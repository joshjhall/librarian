---
name: local-pass-remote-hang-is-a-timeout-gap
description: "A test that passes locally and hangs in CI is usually an unbounded client wait, not a flake — bound every probe and check identity, not just connect"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 237ae268-417c-4953-a378-41e10f8333d5
  modified: 2026-08-29T06:37:14.567Z
---

A suite passed locally in 5.5s and hung CI until it was cancelled at 15 minutes,
leaving orphan `curl`/`python3`. The cause was not flakiness or load: a fixture
squatted a port with a socket that `listen()`s but never replies, so the
readiness probe's **TCP connect SUCCEEDED** and then blocked forever on a
response that never came. An unbounded `curl` inside a bounded 50-iteration poll
makes the whole loop infinite.

It passed locally only because that machine's `curl` gives up on a half-open
connection sooner. Same code, two outcomes — so "green locally" was never
evidence.

**Why:** any fixture that holds a port realistically must `listen()` (otherwise a
competing bind is absorbed by SO_REUSEADDR and the fixture proves nothing). So
introducing contention testing *creates* the half-open-socket case that an
unbounded client wait hangs on. The hang is a consequence of the feature, not
bad luck.

**How to apply:**

- Every network probe in a poll loop needs an explicit timeout (`curl --max-time`,
  `urlopen(timeout=)`). Grep siblings — count the UNBOUNDED calls rather than
  asserting a fixed number of bounded ones, so the check survives added calls.
- Readiness must check **identity**, not just reachability: require the expected
  BODY. Whoever holds a contended port may not be your server, and
  "something answered" → "my server is up" is a false positive that suppresses
  the very retry you added.
- Diagnose by reproducing outside the suite first, then A/B the fix by timing:
  reverted → killed at 90s, fixed → 5.5s. See [[reproduce-outside-the-tool-first]].
- A CI cancellation with orphan processes names the culprit — the orphans are
  your fixture's children.

Related: [[harden-one-knob-grep-every-sibling]],
[[self-skipping-test-hides-the-risky-branch]].
