---
name: issue-432-gate-age-coverage
description: "#432 test-coverage follow-up SHIPPED PR #482; pre-PR review found a real HIGH bug + my own test gave false assurance"
metadata:
  node_type: memory
  type: project
  originSessionId: 15226509-e7c2-48fe-a57b-46a99ea2dd60
  modified: 2026-07-21T21:08:25.764Z
---

Issue #432 (test-coverage follow-ups for golem-resolve.sh / _gate_age_suffix,
from the #422 deferrables) — SHIPPED PR #482 (2026-07-21, L3, PARKED human-merge
per [[auto-mode-blocks-self-merge]]).

Planned as pure test-only (3 gaps): golem-resolve no-jq escaper, golem-resolve
missing-hook exit 1, _gate_age_suffix no-op arms. Two enabling/scope facts:

- **Source guard**: golem-status.sh had NO `BASH_SOURCE==$0` guard; added the
  `return 0`-when-sourced one-liner so tests can `source $STATUS` and unit-call
  render helpers. Direct precedent = golem-resolve.sh:120 /
  golem-gate-watch.sh:842. Nothing sourced it before (grep-confirmed) → executed
  behavior byte-identical.
- **no-jq escaper is only observable at the PAYLOAD golem-resolve emits**, NOT
  the feed: on the full no-jq path the real hook ALSO lacks jq so it re-defaults
  the message. Test via a payload-capturing SINK hook in an isolated
  `<tree>/scripts` + `<tree>/hooks` copy (helper resolves hook RELATIVE to its
  own dir).

**Pre-PR review earned its keep — found a real HIGH bug my coverage brushed
past**: golem-gate-watch.sh feed_snapshot runs ONE `jq -rs` over the whole feed;
a single golem's non-empty-but-MALFORMED `.ts` aborts `fromdateiso8601`
program-wide (exit 5, swallowed by 2>/dev/null) → blanks the ENTIRE BLOCKED list
for EVERY golem. This is the #24 (CLOSED) blast radius re-entered: #24's guard
only screens null/"" (`(.ts|type)=="string" and .ts!=""`), not a strict-parse
failure. FIX = wrap parse in `try (…) catch true` → malformed ts degrades to the
TTL-bypass fresh fallback, localized. My original test COMMENT called this abort
"inert/unreachable" — wrong; corrected it. Same failure class also lives in
golem-event-listener.py fromdateiso8601 (left as-is, sibling).

**My regression test gave FALSE ASSURANCE first cut** → see
[[test-assert-blocked-list-not-feed-echo]]. golem-status.sh echoes the raw feed
JSON under "Recent feed" at the bottom, so `assert_contains "$RUN_OUT" "good-ts
gate"` matched the ECHO even with BLOCKED empty. Fix = anchor on the render-line
form `golem-N — <message>` (em-dash). ALWAYS verify a regression test FAILS with
the fix reverted (revert→run→see FAIL→restore).

Also hit [[edits-landed-in-main-not-worktree]] AGAIN (guard first landed in
/workspace/librarian main) and the [[typos-gate-blocks-push]] gate (it rewrites
the "unparsable" misspelling). State file written to main-checkout
.claude/memory/tmp (the memory root is shared, not worktree-local).
