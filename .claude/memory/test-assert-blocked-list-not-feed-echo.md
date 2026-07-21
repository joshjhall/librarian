---
name: test-assert-blocked-list-not-feed-echo
description: "golem-status tests must anchor on the render-line form, not a bare message substring — the raw feed echo causes false-pass"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15226509-e7c2-48fe-a57b-46a99ea2dd60
  modified: 2026-07-21T17:20:01.226Z
---

golem-status.sh prints the raw feed JSON verbatim under a "Recent feed (...)" section at the BOTTOM of its output. So `assert_contains "$RUN_OUT" "<gate message>"` can match that echo even when the BLOCKED list is EMPTY — a false pass that makes a regression test useless.

**Why:** discovered on #432 (PR #482) — my two-golem malformed-ts regression test PASSED even with the fix reverted, because "good-ts gate" appeared in the feed echo though BLOCKED showed `(none)`.

**How to apply:** anchor BLOCKED-list assertions on the RENDER-line form `golem-N — <message>` (em-dash separator `—`, U+2014), which appears ONLY when the golem actually surfaces BLOCKED — never in the JSON echo. And always sanity-check a regression test by REVERTING the fix, running, confirming it FAILS, then restoring. A test that passes both with and without the fix is guarding nothing. Related: [[ship-review-diff-must-be-faithful]], [[issue-432-gate-age-coverage]].
