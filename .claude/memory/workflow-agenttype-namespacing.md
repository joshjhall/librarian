---
name: workflow-agenttype-namespacing
description: Workflow-tool agent() needs namespaced <plugin>:<name>; Agent tool wants the bare name — opposite. Fixed in #126/PR #128; harnesses now namespaced and a lint gate enforces it.
metadata:
  node_type: memory
  type: project
  originSessionId: 7601b90d-6a82-4f53-87ba-96560d7be13c
---

The `Workflow` tool's internal `agent({agentType})` resolver and the `Agent`
tool's `subagent_type` use **opposite** naming under a marketplace plugin
install:

- **Agent tool**: bare `code-reviewer` resolves; `dev-core:code-reviewer` is
  NOT found.
- **Workflow tool**: bare `code-reviewer` is NOT found; the registry lists only
  namespaced `<plugin>:<name>` (`dev-core:code-reviewer`, `review-audit:checker`,
  `workflow:ci-fixer`, …). This affects same-plugin refs too, not just
  cross-plugin.

**FIXED (issue #126 / PR #128, merged 2026-06-30).** Every bundled `workflow.js`
harness now uses the namespaced `<plugin>:<name>` form (23 refs across 6
harnesses). Map: `code-reviewer`→`dev-core:`, `checker`/`issue-writer`→
`review-audit:`, `ci-fixer`/`rebase-agent`→`workflow:`. So harness-driven
fan-out (ship-issue review, ci-fixer, rebase-agent, codebase-audit) no
longer throws. New harnesses MUST keep using the namespaced form.

**The real CI gate is `tests/lint-skills-agents.sh`** →
`workflow_dangling_agenttypes()` (NOT `validate-crossrefs.sh` — that only checks
SKILL.md `subagent_type`, which correctly stays bare). Pre-#126 it validated
`agentType` by **basename**, so bare refs passed offline while dispatch failed.
PR #128 rewrote it to require `<plugin>:<name>` resolving to
`plugins/<plugin>/agents/<name>.md`; a bare name is now flagged. Also added a
bare-`agentType` MEDIUM heuristic to `check-ai-config`'s `patterns.sh`
(`check_harness_logic`) and authoring notes in `workflow-authoring` /
`adversarial-review`.

NOTE: `merge-protocol.md`'s `~/.claude/agents/code-reviewer/…` mentions are
filesystem-path refs, a DIFFERENT mechanism — never part of #126.

Fallback if a harness ever throws on agentType again: invoke the agent directly
via the Agent tool with the **bare** name. Related: [[two-runtime-model]].
