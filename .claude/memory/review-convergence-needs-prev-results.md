---
name: review-convergence-needs-prev-results
description: review-convergence.sh scores every finding novel unless you pass one --prev-result per earlier cycle
metadata: 
  node_type: memory
  type: feedback
  originSessionId: aa8b1709-8943-49be-8adc-30135b673878
  modified: 2026-08-22T03:59:34.314Z
---

`review-convergence.sh check` computes `duplicate` by comparing fingerprints
against the `--prev-result` files you hand it. Omit them and it cannot see a
repeat: `novel` equals the total, the verdict is `continue` / `C8-novel`, and the
loop runs another cycle. It does not warn — an omitted prior is indistinguishable
from a genuinely new finding.

**Why:** `--prev-result` is **repeatable on purpose** — duplicate detection is
against *all* earlier cycles, not just the previous one, because a finding that
reappears after being skipped for a cycle is still a duplicate. The script's own
comments say a dropped prior is "a wrong verdict computed from
silently-incomplete input, which this script must never emit"; passing only some
of them reproduces exactly that by hand.

**How to apply:** on cycle N, pass `--prev-result` once for every cycle 1..N-1,
keeping each cycle's result JSON on disk for the whole loop. Observed on #734
cycle 4: without priors `continue`/`C8-novel`; with all three priors
`stop`/`C6-duplicate` on identical input.

Related: [[workflow-args-must-be-json-object]],
[[c6-duplicate-stop-can-hold-a-live-defect]].
