---
name: issue-494-checklist-relocation
description: "#494 moved 6 code-reviewer sub-reviewer checklists .md→workflow.js SUBREVIEWERS; issue premise was WRONG (harness is sandboxed, pastes no section); also fixed bloat-glob missing flat agents"
metadata:
  node_type: memory
  type: project
---

**#494 (L3, refactor):** moved the six sub-reviewer checklists
(Security/Bug/Performance/Style/Database/DevOps, ~137 lines) OUT of the
always-loaded `code-reviewer.md` system prompt (424→249 lines, under AGENT_WARN
250) into `code-reviewer/workflow.js` as a `SUBREVIEWERS` const; `reviewerPrompt`
pastes the ONE named checklist inline AFTER the shared cache-stable prefix (#256),
with the JSON footer stated once via `findingsFooter()`. Fail-loud throw on unknown
key.

**The issue's stated mechanism was FACTUALLY WRONG** — it claimed "the harness
already pastes only the named section per line ~281" and proposed a passive
`sub-reviewers.md`. But `reviewerPrompt` pasted NO checklist (it said "use the
Sub-Reviewer Definition IN YOUR INSTRUCTIONS" — read from the agent's own
always-loaded prompt), and the workflow.js engine is sandboxed (no fs — see
[[two-runtime-model]]). Only sandbox-valid realization = string const in the harness.
LESSON: verify an issue's claimed mechanism against the actual code before planning;
audit-filed issues can misdescribe the delivery path.

**Bonus real bug found + fixed:** the check-ai-config bloat glob was `*/agents/*/*.md`
(nested only) in BOTH patterns.py:244 and patterns.sh:248 — it never matched a FLAT
`agents/<name>.md`, so the deterministic scanner never flagged any flat agent file
(only the LLM lens did). Widened to also match `*/agents/*.md` symmetrically (parity
gate stays green) + added flat+nested agent-arm fixtures to
`validate-checker-detectors.sh test_ai_file_bloat` (arm had ZERO coverage before).

**Test-guard gotcha:** `validate-workflow-helpers.mjs` had a blanket
`!reviewerPrompt("bug").includes("undefined")` (#267 diff-region regression guard).
The bug checklist legitimately contains "Null/**undefined** access" → false positive.
Fix = scope the guard to the prompt PREFIX before "Sub-Reviewer Definition (" (the
actual diff region a manifest.diff revert corrupts), not the whole prompt. Same
class as [[edits-landed-in-main-not-worktree]] discipline — worktree guard also
caught my first edit hitting the main-checkout path (I'd Read via the main path).
