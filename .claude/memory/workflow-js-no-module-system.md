---
name: workflow-js-no-module-system
description: workflow.js harnesses cannot be split into importable modules — the Workflow engine has no import/require/filesystem
metadata:
  node_type: memory
  type: project
  originSessionId: 49cfd60a-c2b8-4004-aa76-cb019e6bb6aa
---

The sandboxed Workflow JS engine loads ONE self-contained inline script per
harness with **no `import`/`require` and no filesystem**. So a `workflow.js`
"god module" (e.g. codebase-audit's, 727 lines, 6 schemas + utils + prompt
builders + orchestration) **cannot** be refactored by extracting `schemas.js` /
`prompt-utils.js` siblings — there is nothing to import them with. This is why
`BUDGET_FLOOR` is copy-duplicated across all six harnesses
(`tests/lint-skills-agents.sh:42` documents it), and why issue #78 notes a
harness "can't be imported without executing it."

**Why:** An audit (`/codebase-audit`) will keep re-filing "god module — extract
modules" findings against these harnesses; the literal fix is impossible in this
runtime. Issue #90 was one such finding.

**How to apply:** For a workflow.js "split this file" issue, the in-runtime
remedies are: document the constraint in the harness header, remove genuinely
duplicated constants (e.g. an inline template that duplicates a companion
`.md` — but only if some agent can legitimately source the canonical copy; the
issue-writer agent has **no Read tool**, so codebase-audit's `ISSUE_TEMPLATE`
must stay inline and is instead guarded by `tests/validate-template-sync.sh`),
and add section banners. A further remedy when the file is a multi-mode dispatch:
wrap each mode body in a **named entry-point function** with a small `MODE`
dispatch tail (closure-shared schemas/utils stay at module scope) — this is the
issue's own "separate functions with clear entry points" fallback and is
behavior-preserving. See [[two-runtime-model]].

**Worked precedent (issue #91 → PR #114):** orchestrate's harness had 4 modes as
top-level `if (MODE===…)` early-return blocks. Resolution: `runPool` / `runTrain`
/ `runPollSweep` functions + dispatch tail, plus a "single-file by necessity"
header banner mirroring codebase-audit's (lines ~38-48) that names the impossible
`orchestrate-pool.js`/`orchestrate-train.js` extraction so the audit
self-suppresses. The `phase()`/`agentType` lint is text-grep, so moving calls
into functions is safe; top-level `return`/`await` are both supported by the
engine.
