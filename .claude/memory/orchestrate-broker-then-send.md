---
name: orchestrate-broker-then-send
description: Plan-gate flow is broker→human-decides→ORCHESTRATOR sends the tmux keystroke; never hand the keystroke back to the operator
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8ad52384-dc1c-4058-b9f5-e2707af84d8f
  modified: 2026-08-01T04:13:40.065Z
---

At an `/orchestrate` L1–L3 plan gate, the flow is **broker → human decides → the orchestrator sends the
keystroke itself**. After the operator approves (in-session, e.g. via `AskUserQuestion`), YOU run
`tmux send-keys -t golem-{N} 1 Enter` — do NOT print the command back for the operator to paste.

**Why:** The operator's role is the *decision*, not the physical keypress. Handing the keystroke back defeats
the entire point of the orchestrator brokering the gate. This tripped the session repeatedly (batch 2) — I kept
printing `! tmux send-keys …` after the human had already approved via AskUserQuestion.

**How to apply:** AskUserQuestion "approve?" → answer "approve" → immediately Bash
`tmux send-keys -t golem-{N} 1 Enter` → verify the golem left plan mode (`⏵⏵ auto mode on`, no `⏸ plan mode`;
branch name in status bar). The send is gated by the auto-mode classifier: it is DENIED on an un-directed send but
ACCEPTED once the operator explicitly authorizes it (e.g. "approve all plan gates") — the explicit directive clears
the wall (confirmed 2026-07-15, Batch 3/4).

**The `#29` "human keystroke / real TTY" doc language is misleading** — it's really about an agent *relaying
option 1 through the auto-mode classifier*, NOT `tmux send-keys` from the live session. Filed #280 (clarify
SKILL wording), #281 (verify send-keys is agent-drivable / #29 stale), #282 (classifier non-determinism).
