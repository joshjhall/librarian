---
name: issue-485-monitor-event-driven
description: "#485 flips orchestrate monitor default from persistent sweep to event-driven push gate-watch; sweep now opt-in/cron; shipped PR #504 (L2, awaiting merge); review caught pool-refill-clock orphan"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2e00fe92-7847-4f32-8736-90367f40c1a5
  modified: 2026-07-22T17:48:31.638Z
---

**#485** SHIPPED PR #504 (L2, awaiting human merge) — orchestrate monitor default
flipped from the persistent rolling `golem-status.sh --checkpoint --watch` sweep
(was "on by default at every level", #304) to **event-driven**: the push
gate-watch (`--stream` + `--stream-panes`) is now the default surface; the
rolling status table is **opt-in** (one-shot `/orchestrate status`, or a
`CronCreate` render redirected to a file out-of-band). Supersedes #304. Fixes the
[[token-burn-audit-2026-07-21]] biggest lever + reduces
[[dropped-gate-in-notification-flood]] pressure.

Doc/default change only — NO golem-status.sh behavior change (one-shot
--checkpoint already existed; cadence table + sweep-interval resolver stay valid
for the opt-in sweep). 3 protocol surfaces: monitor-protocol.md Loop step,
mode-protocol.md status-sweep-cadence, SKILL.md Phase M.

**REUSABLE bug from the adversarial pre-PR review (HIGH):** the default-armed
sweep was ALSO the Phase P **pool-refill / gh-poll heartbeat** — "the existing
cadence is the clock" (pool-train-protocol.md § Refill loop, mirrored in
mode-protocol.md + SKILL.md). Gate-watch fires ONLY on gate transitions, never on
"PR merged / slot freed / CI green", so flipping the default silently orphans
pool refill. FIX = Worker-Pool exception: a live pool (pool.queue==accepting)
MUST arm a periodic cadence (opt-in --watch sweep or CronCreate /orchestrate
status) as its refill clock; plain fixed-batch dispatch doesn't need it.
**Lesson: a "default-on background loop" often carries a hidden second duty
(here: the heartbeat that advances OTHER phases) — before removing it as default,
grep for everything that piggybacks on its cadence.** Also caught: don't cite an
undecided ADR sink ("host command-center") as available — soften to a plain file;
fix stale #304 "default-on" docstrings in the scripts the prose points at.

Live-verified #451 AC#3 (bare /golem → priority-select → show → CONFIRM before
worktree): bare /golem picked #451 itself (top priority), confirm gate let me
redirect to #485. #451 AC#1 (L4 auto-merge) still deferred (self-merge blocked
anyway). Teardown: `/golem --teardown 485` after human merges #504.
