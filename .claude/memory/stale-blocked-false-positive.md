---
name: stale-blocked-false-positive
description: "golem-status BLOCKED list pins send-keys-resolved plan gates for the full 3600s TTL (no clearing feed line) → trains you to ignore the list → nearly miss a REAL fresh gate; filed #422; trust the feed/host, not a pane-grep"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-19T22:07:42.759Z
---

During a live L3 batch, the containers **host command-center** showed golem-405
"waiting on feedback" while my **pane-grep** heuristic said "still
implementing." The host was RIGHT: 405 was genuinely gated at its ship-issue
adversarial-review Workflow-run permission prompt. My grep matched the word
"tokens" inside the *gate prompt text* ("Dynamic workflows can use a lot of
tokens…") and I misattributed it as stale implementation output.

**Root cause of the confusion (filed as #422, workflow plugin, sev/high):**
`golem-status.sh` BLOCKED clears a gate ONLY when a newer `idle`/`gate` feed line
supersedes it (within `GOLEM_BLOCK_TTL`, default 3600s). Resolving a **plan gate**
via `tmux send-keys 1 Enter` fires NO `Notification`, so `golem-notify.sh` emits
no clearing line → the stale `gate` line stays "fresh" for up to an hour → the
golem shows BLOCKED long after it's implementing. The render also shows no gate
AGE, so stale and fresh gates look identical. Persistent stale-BLOCKED entries
trained me to dismiss the whole BLOCKED list as noise — and I nearly dismissed
405's genuine fresh gate the same way.

**Why:** the feed channel is authoritative and TTY-free by design; a pane grep is
a lossy heuristic that can match gate-prompt boilerplate. When a host/feed view
and a pane read DISAGREE, read the FULL pane (footer: `❯ 1. Yes…` prompt vs
`⏵⏵ auto mode on`) before trusting either — don't grep-filter the pane.

**How to apply:** (1) A fresh feed `ts` newer than your last send-keys IS a real
new gate — the review-workflow-run permission prompt is the common one at ship
time; approve it (option 1) as a routine gate. (2) Trust the host command-center
/ `feed.jsonl` over a pane-grep when they conflict; when a host/feed view and a
pane read DISAGREE, read the FULL pane footer before trusting either.

**FIX SHIPPED (2026-07-19, #422 branch feature/issue-422, L3):** new `resolved`
feed event kind + `scripts/golem-resolve.sh` helper (the orchestrator calls
`golem-resolve.sh {N}` right after `tmux send-keys 1 Enter`; it forces
`GOLEM_ID=golem-N` because resolution runs from the orchestrator's cwd, else the
hook stamps `golem-?`) → an explicit clearing line supersedes the stale gate on
the next sweep (like `idle`, `resolved` is not in the BLOCKED set, so no reader
change). PLUS golem-status BLOCKED render now shows a `(gated Nm ago)` age
suffix (defense-in-depth). Broker prose wired in orchestrate SKILL.md §Phase D +
mode-protocol.md. Once merged+deployed to /opt, the "expect the golem to STAY in
BLOCKED" caveat is GONE — a send-keys-resolved gate drops out on the next sweep.
Design decision: age lives in the golem-status RENDER, not gate-watch
`feed_snapshot`, to keep `--stream` `emit_transitions` (golem,message) dedup
intact. See [[orchestrate-broker-then-send]].
