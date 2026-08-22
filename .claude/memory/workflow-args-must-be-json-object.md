---
name: workflow-args-must-be-json-object
description: "Workflow tool args passed as a JSON-encoded string silently mislabels the cycle and drops the diff, so every finding scores novel"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: aa8b1709-8943-49be-8adc-30135b673878
  modified: 2026-08-22T03:59:26.150Z
---

The `Workflow` tool's `args` must be a real JSON **object**. Passing a
JSON-encoded *string* does not error — the script's key lookups fall through to
defaults, so the run mislabels itself (`cycle 1`, `phase: pre-pr` regardless of
what you passed), logs `WARNING: no diff supplied`, and silently drops
`prComments`, `deltaDiff`, and `priorBlockingDimensions`.

**Why:** the damage is invisible in the result JSON. Reviewers re-derive the diff
in-agent so the findings are still real and scope survives — but with no
prior-cycle refs reaching it, the convergence predicate scores every finding
`novel`, returns `continue`, and the loop burns another cycle for nothing. A
review that looks like it worked is worse than one that failed.

**How to apply:** pass `args` as an object literal in the tool call. When a
cycle's log says `cycle 1` for a cycle you know is later, or says no diff was
supplied, stop and re-dispatch rather than reading the verdict. Same shape of
mistake as array args elsewhere: a stringified list reaches the script as one
string and `.map`/`.filter` throw.

Related: [[review-convergence-needs-prev-results]].
