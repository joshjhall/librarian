---
name: issue-503-large-file-decompose
description: "#503 large-file decomposition tracking issue — file-length scan baseline, workflow.js no-split constraint, sequenced after #494/#495"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3c0be081-4199-4f38-bfae-4f667d3db8af
  modified: 2026-07-24T04:58:05.284Z
  status: stable
  stale_after: 2026-10-31
  stale_check: "the file-length scan baseline and "#503 open" status — re-check with `gh issue view 503`"
---

# #503 tracks decomposing oversized files (code-health file-length lens)

Filed 2026-07-22, `status/on-hold`, sequenced to run **after #494 + #495** land
(those shrink the prose surface, so re-run the scan and refresh #503's tables
before starting). Cross-linked from #494/#495.

**Key framing gotcha:** the file-length check is a **Pass-2 (LLM) lens**, NOT a
`patterns.sh` deterministic category — there is no script that just prints large
files. Measure line counts directly (`find … | xargs wc -l`) and apply the
skill's language-aware lens by hand.

**Two surfaces:**

- **Prose (SKILL.md/agent .md, ai-file-bloat warn 300/high 500):** the NEW work
  not already tracked = `checker.md` (582), `ship-issue/SKILL.md` (368),
  `audit-ai-config.md` (299). `orchestrate` (478) + `next-issue` (447) → #495;
  `code-reviewer.md` (424) → #494. Fix = move call-specific blocks to on-demand
  files (same pattern as #494/#495).
- **Code (workflow.js):** orchestrate 1419 (was ~440 @ #91), codebase-audit 1137
  (was 555 @ #90), code-reviewer 888, ship-issue 821. **#90/#91 were CLOSED
  because harnesses have NO module system** ([[workflow-js-no-module-system]]) —
  can't split into importable files. "Decompose" = entry-point-fn, header banner,
  and extracting genuinely-duplicated logic (cf. #92 BUDGET_FLOOR), never file splits.
  Frame any harness work this way or it gets re-closed as dup of #90/#91.

**Not in scope:** long `tests/*.sh` (validate-golem-scripts.sh 5094 etc. — test
files legitimately run long); `golem-status.sh` (1015) noted but bash-3.2-bound,
assess only if it grows.
