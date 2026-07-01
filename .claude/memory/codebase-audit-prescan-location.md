---
name: codebase-audit-prescan-location
description: Step 2.5 patterns.sh prescan contract lives in orchestration-protocol.md (not SKILL.md) after PR
metadata:
  node_type: memory
  type: reference
  originSessionId: 2d0d2cb6-f0c4-434f-b3ba-e0bc9c245d9a
---

The codebase-audit deterministic pre-scan ("Step 2.5") that discovers and runs
`check-*/patterns.sh` is authored in:

- `plugins/review-audit/skills/codebase-audit/orchestration-protocol.md` —
  Step 2.5, the full domain-knowledge reference (PR #106 split this out of
  SKILL.md; SKILL.md now keeps only a one-line summary bullet + a pointer).
- `plugins/review-audit/agents/checker.md` — Step 3 Pass 1, the actual
  `bash <skill-dir>/patterns.sh <tempfile>` execution.

Edit both in lockstep or they drift (the `tests/run-all.sh` "SKILL.md ↔ agent
cross-reference integrity" stage guards the pointers, not the prose).

Issue #107 added a source-aware integrity gate here: log `discovered` first;
user-source scripts (`~/.claude/...`) run as-is; project-source
(`.claude/skills/...` in the repo under audit) is skipped unless
`CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1` (exact `1`), with git-tracked only an
existence check, not integrity. The same env var also gates project-level
`audit-*` agent dispatch (the parallel supply-chain surface — project agents
can override built-in scanners). `legacy` source = user-level audit-* agents
which have NO patterns.sh, so that branch never enters the prescan loop (both
docs say `source: user|project`). The harness is sandboxed
([[two-runtime-model]]), so the gate is prose in the agent instructions, not a
standalone script.

**Pitfall that bit this work:** a stale local `main` (19 commits behind
origin, pre-#106) made it look like Step 2.5 still lived in SKILL.md and that
`orchestration-protocol.md` didn't exist — the #107 issue body was actually
correct. Always `git fetch origin main` and branch from `origin/main` before
editing; check `git log HEAD..origin/main -- <target files>` before committing.
