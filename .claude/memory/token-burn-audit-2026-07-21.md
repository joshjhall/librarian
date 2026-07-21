---
name: token-burn-audit-2026-07-21
description: "2026-07-21 four-axis token-burn audit → issues #487-#495; where the live-session burn actually lives"
metadata: 
  node_type: memory
  type: project
  originSessionId: 384cb28b-3451-4b95-aaa9-2d07c8096637
  modified: 2026-07-21T19:17:23.269Z
---

Four-axis efficiency audit (cadence scripts / workflow.js fan-out / always-loaded prose / model tiering), sibling to [[issue-485-monitor-lower-burn]]-style monitor work. Filed #487-#495.

**Tier 1 (highest live payoff, low risk):**

- #487 — golems launch `claude --permission-mode auto` with **NO `--model`** at `golem-launch.sh:383,453` + `worktree-new.sh:116` → whole multi-hour pipeline inherits operator default (Opus). No `GOLEM_MODEL` knob despite clean `config.sh` env convention. Sonnet 5 fine for next-issue→ship; biggest single lever.
- #488 — `golem-status.sh` checkpoint (`:664-797`, `:903-907`) has ZERO change-suppression: full table re-emits every 8min unchanged. Impl half of #485. Also `:495-499` tails 10 raw feed JSON (dup of BLOCKED block), `:783-784` static boilerplate every sweep.
- #489 — `golem-gate-watch.sh --stream-liveness` (`:561-570`) re-emits every heartbeat every 60s NO dedup BY DESIGN; gate `--stream`/`--stream-panes` correctly edge-triggered via `emit_transitions` (`:212-234`) — reuse it for liveness.

**Tier 2 (fable/fan-out):** #490 codebase-audit per-domain fable verify (`workflow.js:842-849`) → collapse to 1. #491 ship-issue TWO fable tail passes rescore+classify (`:720-732`,`:756-769`) ×MAX_CYCLES=3 → merge. #492 ship-issue re-reviews FULL diff every cycle → delta on cycle>1. #493 ci-fixer re-classifies static logs each retry (`:211`) → hoist out of loop (trivial).

**Tier 3 (prose):** #494 code-reviewer.md 6 checklists load ~9×/run, each call uses 1 → on-demand file. #495 state-format.md 710L dep-queue block rare-path + standing-rules dup'd across 3-4 always-on files → split + define-once.

**Already minimal (no action):** subagent model tiers deliberate (haiku/fable/sonnet, opus only debugger/skill-author/agent-author/audit-ai-config); orchestrate+rebase harnesses; gate `--stream` dedup; #256 cache-stable diff dup.
