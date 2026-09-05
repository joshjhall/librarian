---
name: read-issue-comments-before-planning
description: The approach may be DECIDED in a comment that overrides the body's framing — read `--comments` before planning, not just the body
metadata:
  type: feedback
---

`gh issue view N` shows the **body only**. Run `gh issue view N --comments`
before planning any issue, and read the comments as potentially *authoritative*
— an operator may have recorded the chosen approach there, and that decision
**overrides the body's framing**, which is often older than the decision.

The failure mode is not "missed a detail". It is planning a well-researched
answer to a question that was already settled, then putting it to the human as
an open choice — visible work that has to be discarded.

**Why:** an issue body is written when the problem is found; a decision comment
is written when someone thinks it through. The body frequently enumerates
options *on a premise the comment falsifies*. On #907 the body offered three
approaches on the premise that "only an LLM can run this sweep"; the decision
comment recorded that the premise was incomplete (the scanner ships a
deterministic pre-scan needing no LLM) and picked a fourth option none of the
three covered — plus four binding scope constraints that shaped every file.

**How to apply:** fetch body and comments in the same first call. If a comment
records a decision, treat its constraints as requirements, restate them in the
plan, and carry the *rejected* alternatives with their reasons into the code
header or PR body so nobody re-litigates them. An "acceptance criterion" like
"a decision is recorded" is often **already satisfied** by such a comment —
check before treating it as work. Related:
[[surface-followups-before-declaring-done]].
