---
name: gate-watch-misses-standing-gates
description: golem-gate-watch fires only on transition INTO a gate; a gate already standing when the watch arms is never surfaced
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T08:26:30.910Z
---

`golem-gate-watch.sh --stream/--stream-panes` emits only on the **transition
into** a fresh gate. A gate that is **already standing** when the Monitor arms
is treated as already-seen and is **never** emitted. So arming the gate-watch
*after* golems have already blocked leaves them parked invisibly — observed live
2026-07-24: 3 L3 golems dispatched, gate-watch armed later, all 3 sat at
plan/permission gates awaiting approval with zero pings until a manual pane read
found them. Arm gate-watch AT dispatch, not after.

**Timezone-mixing bug (separate, worse):** I reported the park as "~8h" — it was
**~3h**. `tmux ls` "created" and `find -printf '%T+'` emit **LOCAL** time; I
stamped caches and read `date -u` in **UTC**, then compared across the two clocks,
inflating every age by exactly the offset (CDT = UTC−5, so +5h). Also
`golem-status.sh --checkpoint` ELAPSED reads the cache's `started`, so a
backfilled `started` shows a bogus tiny elapsed (6s) that hides true age.

**Why:** (a) push-only monitoring has a cold-start blind spot; (b) mixing local
and UTC clocks in one comparison silently adds the tz offset to every duration.

**How to apply:** (1) Arm gate-watch AT dispatch (Phase D), not later. (2) When
armed late, immediately do ONE direct `tmux capture-pane -p` sweep of every
`golem-*` to catch already-standing gates. (3) Keep a periodic pull cadence (cron
`/orchestrate status` or the refill sweep) reading panes directly as
belt-and-suspenders. (4) **ONE CLOCK, UTC, everywhere.** `tmux ls`/`find`/bare
`date` are LOCAL — convert before comparing to a UTC `date -u`, or don't compare.
(5) Trust the golem's **own in-pane timer** ("1h 24m", clock-independent) over
your own elapsed arithmetic. (6) Distrust ELAPSED when `started` was backfilled.
Relates to [[dropped-gate-in-notification-flood]] and [[stale-blocked-false-positive]].
