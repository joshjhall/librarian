---
name: l3-broker-plan-gate
description: "Standard L3 plan-gate flow — orchestrator presents each golem's plan in-session with options, human decides HERE, orchestrator sends the keystroke back to the golem (never hand the operator a TTY)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 10478e43-b9c4-4a7c-a620-83c6efd01629
---

For L3 golems the operator wants the **orchestrator-brokered** plan gate as the DEFAULT, not the attach-the-TTY-yourself flow the skill prose describes:

1. Golem parks at `ExitPlanMode` (surfaced by the armed gate-watch channels).
2. Orchestrator reads the plan (from the tmux pane / `~/.claude/plans/*.md`) and **presents it in-session** with options (approve / refine / reject) via `AskUserQuestion`.
3. Operator decides HERE — a quick in-session review, not by attaching.
4. Orchestrator **sends the decision back to the golem** with `tmux send-keys -t golem-N 1` (option 1 = "Yes, and use auto mode" → same session continues autonomously to a PR).

**Why:** the operator wants to review plans at the orchestrator surface (all golems in one place) and keep hands off individual TTYs. Their explicit in-session decision IS the human authorization — it clears the auto-mode classifier wall that otherwise denies an un-directed relayed send (confirmed batches 3/4).

**How to apply:** never tell the operator to `golem-attach.sh N` and press the key themselves for a routine plan approval; broker it. Only fall back to attach when the plan needs hands-on refinement in-session that can't be relayed as a single keystroke. See [[orchestrate-broker-then-send]] (SENDS after approval, never hands back) and the #29 note that option-1 is a human keystroke — satisfied here by the operator's in-session decision.
