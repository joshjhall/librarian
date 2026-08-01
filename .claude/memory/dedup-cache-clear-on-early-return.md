---
name: dedup-cache-clear-on-early-return
description: "A change-suppression signature cache must be cleared on EVERY early return, or a vanish-then-reappear at the same state is wrongly suppressed (#488)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b3100c69-fe8e-4fa0-9335-e1a0ad5da29c
  modified: 2026-08-01T04:17:49.779Z
---

When a renderer suppresses no-op output by comparing a **signature** of the
current state against the previous one, every early return has to clear that
cached signature — not just the happy path.

Caught as a HIGH review finding in #488 (PR #499), where
`golem-status.sh --checkpoint --watch` buffers the table into `cp_body` and an
actionable-state signature into `cp_prev_sig`, collapsing a byte-identical sweep
to a `— no change since HH:MM` heartbeat. The two early returns (empty state,
`jq` missing) returned WITHOUT clearing `cp_prev_sig`. So a fleet that vanished
and then reappeared at the same state matched the stale signature and was
suppressed — the operator never saw it come back.

**How to apply:**

- Treat the signature cache as state that every exit path owns. Grep each
  `return`/`exit` in the render function and ask what the cache says after it.
- Keep volatile fields OUT of the signature (elapsed, token counts, rates) or
  nothing ever dedups; keep the actionable state IN or real changes vanish.
- Suppression must be **display-only** — the underlying scrape/persist should
  still run every sweep, so a burn baseline or counter never drifts.

**Sibling lesson from the same PR:** a print→buffer refactor needs explicit
**byte-parity** tests (this one dropped a blank line after the pool header and
lost a caveat on the one-shot path) plus a **zero/empty fixture** — the six
original tests all planted at least one row, so the zero path was never
exercised, which is also how the [[grep-c-zero-count-exit-1]] bug survived.

Related: [[dropped-gate-in-notification-flood]] (the notification pressure this
reduces), [[harden-one-knob-grep-every-sibling]] (the set-u crash found in the liveness
channel).
