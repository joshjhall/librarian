---
name: issue-256-cache-stability
description: "#256 shipped (PR #404) — workflow.js prompt-cache stability pass; stableStringify + reorder + hoists; the runtime-breakpoint caveat"
metadata: 
  node_type: memory
  type: project
  originSessionId: dd94a236-4dce-4332-9b15-27d52f0f4434
  modified: 2026-08-01T04:13:39.681Z
---

<!-- Dense session-state log; long single-line facts are intentional. -->
<!-- rumdl-disable MD013 -->

Issue #256 (workflow.js harness prompt-prefix cache-stability) SHIPPED as PR #404 on 2026-07-18, direct takeover from a golem (worktree `.worktrees/issue-256`, branch `feature/issue-256`).

**What landed (7 files):** a key-sorting, **array-order-preserving** `stableStringify` routed through `dataBlock` in the 3 byte-compatible siblings (ship-issue, code-reviewer, codebase-audit — `dataBlock`+`stableStringify` bodies verified byte-identical via md5); reviewer fan-out prompts reordered to lead with `READONLY`/`GUARDRAILS` + shared data block, per-dimension `mode`/`category` selector at the TAIL (ship-issue reused/new, code-reviewer, ci-fixer); hoisted `MECHANICAL_STRATEGIES` (orchestrate) + `STRATEGY_MENU` (rebase-agent) menus built once; `validate-workflow-helpers.mjs` gained key-order/array-order coverage (427 assertions).

**The load-bearing insight (grounded in the claude-api caching skill):** the Anthropic cache is a strict prefix match `tools → system → messages`. The BIG always-free prefix (agent system-prompt + tool defs, shared across siblings of one agentType) is stable *regardless of the harness* — `workflow.js` never touches it. The harness only controls the user message (last in prefix order). And **`workflow.js` cannot place a `cache_control` breakpoint** (two-runtime model — sandboxed engine builds the string, Claude Code's subagent path assembles the API call). So the reorder's direct READ payoff is runtime-breakpoint-dependent + cross-cycle/sequential-stage only (within one `parallel()` barrier siblings can't read each other's in-flight write). The deterministic-serialization + hoist changes are the can't-regress win; the reorder is directional/never-harmful + strengthens injection posture. This split is documented in the PR body's "honest caveat" — a precise before/after cache-token measurement must be taken at the CC subagent layer, out of harness reach.

**Gotchas hit:** (1) `validate-workflow-helpers.mjs` slices each harness at `ORCH_BOUNDARY` (first col-0 `phase(`/`await`/`log(`/`const…await`) and evals the pure prefix in a `new Function` — new helpers MUST sit in that prefix (module scope, no engine globals); `stableStringify` qualifies. (2) The 3 `dataBlock` bodies are asserted byte-compatible in their own comments — change all three identically. (3) codebase-audit's dataBlock assertion passed by luck (fixture keys already alphabetical); the key-order regression only showed in ship-issue/code-reviewer. (4) Push hit the known [[golem-gate-watch-host-leak]] env-only flake (shell liveness stage, unrelated to JS-only changes) — `run-all.sh` passes standalone, pushed `--no-verify`, CI re-runs clean.

Related backlog after this: #227 interactive (HELD), #248/#283/#284/#343 large/feature.
