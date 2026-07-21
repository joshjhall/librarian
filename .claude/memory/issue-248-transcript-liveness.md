---
name: issue-248-transcript-liveness
description: "SHIPPED PR #473 — headless-golem idle/error detection via transcript stop_reason; new golem-transcript-liveness.sh tier; review caught working-staleness + usr-bin-hardcoding regressions"
metadata: 
  node_type: memory
  type: project
  originSessionId: b6e2a2a7-abdc-4618-afb1-bff7f121562c
  modified: 2026-07-21T21:02:04.510Z
---

SHIPPED PR #473 (2026-07-21, L3, PARKED human-merge; issue #248, fast-follow of

# 245/#229). Headless golems (no host-visible tmux) got no idle/error signal —

`pane_liveness_class` scrapes tmux, so they fell through to the bare mtime
heartbeat. Fix = new **`golem-transcript-liveness.sh`**: TTY-free classifier
reading the golem's on-disk Claude Code transcript, wired as a tier in
`golem-gate-watch.sh` `liveness_snapshot()` BETWEEN the tmux-pane read and the
mtime heartbeat.

**The signal** (reusable): the last TOP-LEVEL (`isSidechain==false`) `type=="assistant"`
record's `message.stop_reason` — `tool_use`=working, `end_turn`/`stop_sequence`=idle;
`isApiErrorMessage==true` OR a trailing `type=="system"` `Unknown command` record =
errored (#229). Structured JSON fields, NOT a scrollback scan → immune by
construction to the self-trip `pane_liveness_class` had to footer-anchor (#246).
Reuses `golem-token-scrape.sh`'s worktree→`<projects>/<slug>/` slug (abs path,
`/`+`.`→`-`, newest-mtime `*.jsonl`). Mode-2 only; Mode-3 container transcript
isn't host-readable → exit 2 → mtime fallback (no special-casing). Real API-error
records DO carry stop_reason (`stop_sequence`) — verified on-disk.

**Two adversarial-review catches (both real, both fixed on the PR):**

1. `working` verdict had NO staleness bound → a crashed process frozen mid-`tool_use`
   reports `working` forever, and the caller's `continue` short-circuits the mtime
   stall check → headless golem loses stall detection entirely. FIX = bound `working`
   by the transcript file's own mtime (`GOLEM_STALL_THRESHOLD`, default 1200s); stale →
   demote to indeterminate (exit 2) so the mtime heartbeat regains stall detection.
   `idle`/`errored` NOT mtime-gated (a long-idle golem is correctly idle).
2. My staleness fix used `/usr/bin/stat` + `/usr/bin/date` — the recurring
   [[usr-bin-hardcoding-golem-scripts]] class, contradicting the file's OWN
   portability header; off-/usr/bin the `||true` swallowed exit-127 and silently
   defeated the guard. FIX = `command stat`/`command date`. Lesson: when ADDING code
   to a fail-loud golem script, re-check the `command <tool>` idiom on every new
   coreutils call.

**Rebase gotcha:** #464 (issue #446) landed on main mid-flight and touched the SAME
`liveness_snapshot` + header region with a pane `died — API error` class. Semantic
overlap, not textual — resolved by MERGING both: #464's `died` case stays in the
pane `case "$pclass"`, my transcript tier follows it. Both feature's tests coexist
(40 gate-watch tests). Deferred low/medium findings → follow-up #474 (Mode-3
coverage, API-error robustness, 2 precedence test-gaps).
