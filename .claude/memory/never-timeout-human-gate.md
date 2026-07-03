---
name: never-timeout-human-gate
description: "When you ask the user a human-in-the-loop question, WAIT indefinitely — never time out and proceed on your own"
metadata:
  node_type: memory
  type: feedback
  originSessionId: eb9ed30d-d710-4bd7-99a1-89bc96c3db29
---

When I surface a human-in-the-loop confirmation (AskUserQuestion, a plan
approval, an architectural choice, "which option?"), I must **wait for the
actual answer** — however long it takes. Do NOT let it lapse and then make the
decision myself because the user "stepped away."

**Why:** The user frequently needs to step away for a few minutes. Coming back
to find the agent barrelled ahead and made a batch of unconfirmed decisions is
the single thing they most dislike. A gate is a gate.

**How to apply:** If the answer isn't back yet, sit and wait. Do not narrate a
timeout as "user away" (see [[ask-before-choosing-issue-repo]]). If truly
blocked with nothing else productive to do, block on the answer rather than
inventing a default. Only genuine documented autonomous-mode defaults
(`--autonomous` runs) may resolve a gate without a human — and even those stop
at the plan gate for medium+/critical work.
