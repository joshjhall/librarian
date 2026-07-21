---
name: issue-458-footer-lines-env-test
description: "SHIPPED PR #479 — GOLEM_PANE_FOOTER_LINES env-override test across all 5 footer-keyed pane matchers"
metadata: 
  node_type: memory
  type: project
  originSessionId: 21c0e4d4-1631-4a61-8f2a-b50f8050cf33
  modified: 2026-07-21T16:10:55.292Z
---

SHIPPED PR #479 (2026-07-21, L3, PARKED human-merge): #458 test-only follow-up
from [[issue-452-footer-anchor-matchers]] review. Added
`test_pane_footer_lines_env_overridable` to `tests/golem-gate-watch.sh` mirroring
`test_liveness_threshold_env_overridable` — pins `${GOLEM_PANE_FOOTER_LINES:-8}`
(golem-gate-watch.sh:119) reaches the sourced matchers in BOTH directions
(shrink→3 hides in-window trigger; enlarge→12 reveals out-of-window one).

**Reused `_pane_rc` helper** (tests:43) — sources script in subshell so a
`GOLEM_PANE_FOOTER_LINES=N` env prefix reaches the source-time read.

**Review drove scope-up, not down:** first draft covered only 2 of the 5
matchers the issue names; adversarial pre-PR harness (0 blocking, 2 deferrable)
flagged coverage-gap HIGH-0.85 + scope-drift LOW — I fixed in-PR (cheap,
HIGH-certainty, and full 5-matcher coverage IS the issue's stated scope) rather
than defer. Now covers gate/fork/plan_gate/turn_end + `pane_liveness_class`.

**Gotchas:** (1) `pane_liveness_class` returns a CLASS STRING not rc → capture
stdout, and set the env var BEFORE `source` (NOT `pane_footer_lines=12` directly,
which bypasses the `${VAR:-default}` wiring under test). (2) `export`
GOLEM_PANE_FOOTER_LINES in that subshell to silence shellcheck SC2034 (sourced
reader is invisible to shellcheck). (3) `pane_is_api_error` (#446) is OUT of
scope — keys primary match off `$pane_error_lines`, uses footer only for its
spinner-veto guard.
