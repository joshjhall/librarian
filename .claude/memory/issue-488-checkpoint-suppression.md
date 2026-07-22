---
name: issue-488-checkpoint-suppression
description: "#488 SHIPPED PR #499 (L1): golem-status checkpoint change-suppression; buffer+signature; reusable grep-c bug"
metadata: 
  node_type: memory
  type: project
  originSessionId: bc646c9d-c374-405f-9c2e-5183bd04bb68
  modified: 2026-07-22T00:46:36.181Z
---

**#488 → PR #499** (L1, awaiting human merge). `golem-status.sh --checkpoint
--watch` re-emitted the whole per-track table every sweep even when nothing
changed (impl half of #485). Fix: `render_checkpoint` buffers the table into
`cp_body` + an **actionable-state signature** into `cp_sig` (per-row
`golem|statecol` + pool header + live tails; volatile ELAPSED/TOKENS(Δ)/rate
EXCLUDED), then in watch mode a byte-identical signature collapses to a
`— no change since HH:MM (N golem(s))` heartbeat. Module-scope `cp_prev_sig`/
`cp_last_emit_at` persist across sweeps (one process); one-shot always renders
full. **Both early returns (empty-state, jq-missing) must clear cp_prev_sig** or
a vanish→reappear at the same state is wrongly suppressed (review Bug 1, HIGH).
Token scrape/persist still fires every sweep → suppression is display-only, burn
baseline never drifts.

Also: verbose feed tail (raw 10 JSON lines) → one-line count; static cache-mirror
caveat → once-at-startup stderr (both one-shot + watch paths).

REUSABLE BUGS the review caught: (1) [[grep-c-zero-count-exit-1]] in the
heartbeat count; (2) byte-parity regressions from the print→buffer refactor
(dropped blank line after pool header; one-shot lost the caveat). Lesson: a
render-buffering refactor needs explicit byte-parity + zero/empty-fixture tests.
8 tests total, all revert-fail verified. See [[dropped-gate-in-notification-flood]]
(the flood pressure this reduces).
