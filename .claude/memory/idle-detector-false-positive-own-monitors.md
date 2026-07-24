---
name: idle-detector-false-positive-own-monitors
description: "golem-gate-watch --stream-panes idle-at-prompt (#447) false-fires when a golem is parked waiting on its OWN background Monitors"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T15:50:52.406Z
---

`golem-gate-watch.sh --stream-panes` last-resort matcher (#447: "⚠ idle at
prompt — turn ended, awaiting input") **false-fires** when a golem is legitimately
parked waiting on its **own** background Monitor tasks (e.g. ship-issue's
review-harness workflow + a CI Monitor). The pane paints the plain
`⏵⏵ auto mode on` footer with no `esc to interrupt` run-spinner for a tick — the
exact signature #447 keys on — even though the golem is alive with a queued next
action.

Observed live 2026-07-24: golem-491 (PR #514, ship-issue review harness) fired
this **twice** while its harness advanced 4/6 → 5/6 agents and tokens climbed
421k → 455k. Footer showed `PR #514 · 2 monitors · Waiting for 1 dynamic workflow
to finish`.

**How to tell real from false (always verify the pane, never auto-act):**

- FALSE (working): footer names monitors ("N monitors" / "Waiting for … workflow
  to finish"); review-agent count or token counter ADVANCED since last read;
  pane text shows a queued next action.
- REAL (stall): no monitors pending; token counter FROZEN across the 45–60m
  window; awaiting a human input with nothing in flight (e.g. commit signing
  halted on a locked vault, per #447's own example).

Two-poll debounce doesn't separate "turn ended, human needed" from "between
turns, waiting on own monitors" (the footer holds stable across both polls).
**FILED as #517** (fired 3× on golem-491): root cause `pane_is_turn_end`
(golem-gate-watch.sh:508-512) keys only on absent `esc to interrupt` spinner; fix
= exclude when footer/body shows `N monitor(s) still running` / `Waiting for …
dynamic workflow` / the `next-issue-review N/6 agents` harness footer. Until fixed,
verify the pane every time (advancing tokens / "N monitors" = working). Relates to
[[gate-watch-misses-standing-gates]], [[frozen-counter-is-done-not-wedged]],
[[dropped-gate-in-notification-flood]].
