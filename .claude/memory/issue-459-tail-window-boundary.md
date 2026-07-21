---
name: issue-459-tail-window-boundary
description: "SHIPPED PR #480 (2026-07-21, L3) — tail-window boundary cases for footer-anchored pane matchers; #459 follow-up"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2ec2dbf0-e5e2-4159-874e-2f09829130f3
  modified: 2026-07-21T16:47:17.431Z
---

SHIPPED PR #480 (2026-07-21, L3, MERGED clean) — #452/#457 review follow-up (test-only, effort/trivial).

Added exact tail-window boundary assertions to `tests/golem-gate-watch.sh` for
`pane_is_plan_gate` and `pane_is_gate`: the two existing footer-anchoring blocks
only covered "well outside" (10 filler) and "last line", never the edge of the
default 8-line window. Boundary construction (verified empirically against the
real sourced matchers): trigger phrase + **7 filler = 8 lines** → phrase at
Nth-from-last → `tail -n 8 <<<` INCLUDES → rc 0; phrase + **8 filler = 9 lines**
→ (N+1)th-from-last → EXCLUDED → rc 1. The `<<<` here-string trailing newline is
the off-by-one trap #459 called out — the boundary is exact, no fencepost slop.

Extended the two blocks in place (local `edge_in`/`edge_out`), no new test fns.
41/41 pass; portability + shellcheck clean.

Adversarial pre-PR review: 0 blocking, 1 deferrable (HIGH-certainty coverage-gap,
behaviorally verified) — the same `tail -n "$pane_footer_lines" <<<` idiom is
shared by 3 MORE matchers (`pane_is_fork`, `pane_is_turn_end`,
`pane_liveness_class`) that only have the coarse cases; a regression to the
shared idiom in one of those wouldn't be caught. Out of #459's named scope (2
matchers) → filed as follow-up **#481** (extend the edge pair to all 5
footer-keyed matchers; `pane_liveness_class` returns a string so assert the class
like `test_pane_footer_lines_env_overridable` does). See [[issue-458-footer-lines-env-test]],
[[issue-452-footer-anchor-matchers]].

L3 flow was clean end-to-end (no gotchas): plan gate approved, pushed, PR, CI
7/7 green, worktree-aware squash-merge landed, #459 auto-closed via Closes
trailer, remote branch + state file cleaned up.
