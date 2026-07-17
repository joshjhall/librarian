---
name: golem-notify-feed-cant-classify-forks
description: "golem-notify feed channel structurally can't classify in-turn AskUserQuestion forks; only the deterministic ESCALATION: path + the pane channel"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2f20e6d2-5247-4862-913c-53675082dbdd
---

#321 (PR #342) closed the deferred secondary item from #257/PR #320 as
**document-and-close**, not implement.

An in-turn `AskUserQuestion` fork is surfaced via the Claude Code SDK
`canUseTool` callback, **not** the async `Notification` hook event, so it never
reaches `golem-notify.sh` as an escalation. A plain permission `Notification`'s
`message` is not stable/machine-parseable and carries no multi-option/tool-name
field — so the feed channel has no fork-specific signature to key on, and any
heuristic would risk false positives on the fail-loud `gate` default.

**Why:** the two channels agreeing on "escalation" is only expected for the
deterministic `ESCALATION:`-prefixed path (synthesized by hand in
`next-issue/escalation-protocol.md`). The pane channel (`golem-gate-watch.sh`
`pane_is_fork`, #320) is the *only* surface that observes a live in-turn fork
(its modal overlay). The feed never receives one.

**How to apply:** don't re-file "make the feed classify AskUserQuestion forks" —
it's structurally impossible without a stable Notification signature. The
boundary is now documented in `golem-notify.sh`'s classifier comment and pinned
by `test_classifier_askuserquestion_stays_gate`. Related: [[two-runtime-model]],
[[workflow-js-no-clock]].
