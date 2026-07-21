---
name: issue-462-tracks-build-order
description: "#462 SHIPPED PR #483 — orchestrate/tracks build-order-aware composition; deps_honored display-field bug pattern"
metadata:
  node_type: memory
  type: project
  originSessionId: 9a12ef77-0bc9-4d5f-b8c1-3a319548e421
  modified: 2026-07-21T21:07:51.379Z
---

SHIPPED PR #483 (2026-07-21, L3, PARKED human-merge — auto-mode blocks
self-merge). Issue #462: `orchestrate/tracks` `composeTracks` composed lanes
PURELY by predicted file-overlap, no build-order notion → a dependent dispatched
as track HEAD with unbuilt deps (deps are directed+semantic, may share ZERO
files, so overlap graph can't see/orient the edge). Live repro 2026-07-20 had to
hand-author tracks.json.

**Fix**: two-level sort = build order first, file-overlap second. New
module-scope helpers `buildClusters` (union-find weakly-connected components over
optional per-item `deps`) + `topoOrderCluster` (Kahn, deepest-dep-first, ties by
priority, cycle→priority-fallback never loops). Existing greedy runs over
clusters-as-units. Oversized cluster splits (topo-prefix lands, dependent tail
defers). `deps` is PURE INPUT (setup flow parses Depends-on/Blocked-by/native
blockedBy; composeTracks stays side-effect-free) → no-deps output byte-identical
to prior greedy (backward-compat guard test). Files: workflow.js +
pool-train-protocol.md + tracks.schema.json + validate-workflow-helpers.mjs.

**REUSABLE BUG PATTERN — display field derived from RAW INPUT vs ACTUAL STATE.**
I added a `deps_honored` per-lane display field (`["#19->#22"]`) computed from raw
`it.deps` membership. Adversarial review (cycle 2, HIGH 0.95 dynamic-execution)
caught: when a cycle made topoOrderCluster DROP an edge + fall back to priority
order, deps_honored still listed the dropped edge — even REVERSED vs actual lane
order → operator-facing evidence contradicts the actual order + the rationale
cycle note. FIX = derive from ACTUAL placed positions (`pos.get(d) <
pos.get(n)`), not raw input. Also: un-deduped `deps` → duplicate honored edges
(fix `[...new Set(...)]`). Lesson: a field that explains "why the state is X"
must be computed FROM state X, never re-derived from the inputs that were
supposed to produce X.

**Review flow gotcha**: pre-PR review harness has NO wall-clock bound; one
correctness reviewer ran >20min BOTH cycles (unbounded via
workflow-wall-timeout.sh: L3 auto-extends at 20→40min ceiling, then TaskStop +
recover-journal-partials.sh). Cycle 1 wall-timed-out (partial → clean forced
false, recovered 5 findings incl. the deps_honored dead-schema catch); cycle 2
completed clean. Omitting the `diff` arg is a SUPPORTED fallback (reviewers derive
`git diff origin/main...HEAD` in-worktree, byte-faithful — NOT a paraphrase, so
[[ship-review-diff-must-be-faithful]] not violated). Deferrables (overlap-branch
coverage, direct helper unit tests, diamond graph, schema-conformance test) → #484.
