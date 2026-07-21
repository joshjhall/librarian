---
name: ship-review-diff-must-be-faithful
description: "ship-issue adversarial review — the `diff` arg IS the bytes reviewers read; never pass a paraphrased/abbreviated diff"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 920860ad-58de-4fb6-8393-b12679cdb3dd
  modified: 2026-07-21T05:14:36.135Z
---

The ship-issue pre-PR review harness (`Workflow` on
`ship-issue/workflow.js`, `phase: "pre-pr"`) treats the `diff` arg as the
**authoritative bytes the reviewers read** (#267 — the manifest step no longer
transcribes it). So the `diff` MUST be the byte-faithful `git diff
origin/main...HEAD`, not a hand-shortened summary.

**Why:** on cycle 3 I passed an abbreviated/paraphrased test diff (placeholder
`assert ...` lines instead of the real assertions) to save typing. Caught it
immediately and `TaskStop`'d + relaunched with the faithful diff — but a
paraphrased diff makes every reviewer analyze code that isn't what you're
shipping, so findings are meaningless.

**How to apply:** capture `git diff origin/main...HEAD > /tmp/diff.txt`, Read it,
and pass that exact content as `diff`. If it's large, still pass it whole — the
harness supports omitting `diff` (each agent derives it in-agent) but NEVER pass
a lossy one. Same rule for the `pr-cycle` phase.
