---
name: sync-region-boundary-predicts-stale-arms
description: A past widening reached only the arms inside a sync region; every arm outside one is presumed stale until re-checked
metadata:
  node_type: memory
  type: feedback
---

When an earlier change widened a list (extensions, keywords, categories) across
several sites, it reached the sites a gate was **watching** and stopped there.
The boundary of the watched region predicts, in advance, which sites are stale.

Worked example (#840, following #568): `.mjs`/`.cjs` were present in exactly the
two `check-code-health` arms sitting inside `# >>> shared:` regions pinned by
`validate-shared-scanner-sync.sh`, and absent from all four arms outside one —
in `check-code-health`, `check-security`, `check-lifecycle` and
`check-docs-missing-api`. The result was an intra-scanner contradiction: a
`console.log` in `foo.mjs` was caught while an empty `catch {}` in the same file
was not. The issue named two gaps; the boundary predicted, and measurement
confirmed, four.

**Why:** whoever did the original widening had a gate telling them when they had
missed a synced copy, and nothing telling them about the unsynced ones. The gate
shaped the diff. This compounds with [[parity-gate-hides-shared-defect]]: the
gaps were **symmetric** across both runtimes, so the py/sh parity gate compared
two silences and passed, and the per-cell matrix gate passed too because the
matrix *honestly recorded* the narrowing as `M (js/jsx only)`. A correct
description of a defect is still a defect.

**How to apply:** before concluding a widening is complete, grep the widened
token across every sibling site and sort the hits by whether they sit inside a
watched region. Treat every unwatched site as unverified until probed. Probe by
running the real scanner on a fixture in the new extension **and** on its
already-covered twin — the twin is the control that distinguishes a fixed arm
from a fixture that would have fired anywhere. See
[[harden-one-knob-grep-every-sibling]] and
[[issue-premise-may-undercount-defects]].
