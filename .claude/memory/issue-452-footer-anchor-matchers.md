---
name: issue-452-footer-anchor-matchers
description: "SHIPPED PR #457 (2026-07-20, L3) — footer-anchor golem-gate-watch pane_is_plan_gate/pane_is_gate; retrofit of #246 protection the two oldest matchers predated"
metadata: 
  node_type: memory
  type: project
  originSessionId: 91d6fa1f-3eca-4b79-856b-09ef66279a4d
  modified: 2026-07-21T03:51:20.839Z
---

# 452 SHIPPED as PR #457 (2026-07-20, L3, in-worktree `.worktrees/issue-452`)

`golem-gate-watch.sh` `pane_is_plan_gate`/`pane_is_gate` matched `case "$1"`
(whole captured pane) → false plan/permission-gate push when a golem's
scrollback merely *contained* a trigger string (editing the script, writing
fixtures, `cat`-ing a file). Fix = anchor both to `footer="$(/usr/bin/tail -n
"$pane_footer_lines" <<<"$1")"; case "$footer"`, mirroring `pane_is_fork` /
`pane_liveness_class` — the #246 protection those two older matchers predate.

## 447 ([[issue-447-turn-end-pane-push]]) added footer-anchored `pane_is_turn_end`

but deliberately did NOT retrofit these two, so genuinely uncovered.

Now FIVE matchers key off `$pane_footer_lines` (`${GOLEM_PANE_FOOTER_LINES:-8}`).
Tests: extended `test_pane_is_plan_gate`/`test_pane_is_gate` with the `filler`
(l1..l10) scrollback-vs-footer idiom from `test_pane_is_fork_footer_anchored`.

Adversarial pre-PR review: CLEAN (0 blocking), 2 low deferrables filed as **#458**
(GOLEM_PANE_FOOTER_LINES env-override test, mirror test_liveness_threshold_env_overridable)
and **#459** (tail-window boundary/off-by-one cases). Note: the `correctness`
review agent ran 620s (30 tool calls) — pushed total wall to ~11min, still well
under the L3 40min ceiling; wall-timeout helper returned continue at 5min.
