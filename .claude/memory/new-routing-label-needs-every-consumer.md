---
name: new-routing-label-needs-every-consumer
description: A routing row keyed on a classification label routes NOTHING until the classifier emits that label — and the doc table is never the only consumer; the generated prompt is what actually runs
metadata:
  node_type: memory
  type: feedback
---

Adding a row to a **routing** table (`<label> -> <domain>`) does nothing unless
the **classifier** upstream actually produces `<label>`. Add the row alone and
the new domain appears in the domain list, is dispatched, receives an **empty
file list**, and reports a clean result over files it never read. Nothing errors.
The feature ships inert, and every doc-level assertion about it passes.

Two compounding traps, both live in #670:

1. **The new label usually overlaps an existing one.** A memory-bundle file is
   `.md` (Doc) under `.claude/` (AI Config), so it already matched two rows. A
   new row without an explicit **precedence** rule loses to the broader
   patterns, and the label is never emitted even after you add it.
2. **The prose table is not the only consumer, and often not the running one.**
   The same routing lived in three places: the protocol markdown (documentation),
   the classifying agent's own step (`checker.md`), and a **generated**
   `workflow.js` prompt string — the literal instruction the map agent receives
   at runtime. Fixing only the markdown leaves production unchanged while
   reading as fixed.

**Why:** this fails in the silent direction. An unreachable domain and a domain
that legitimately found nothing produce identical output — an empty finding
list — so the usual "did it run?" check cannot tell them apart.

**How to apply:** when adding a routing label, grep the label's SIBLINGS
(`ai-config`, `doc`, …) across the whole repo, not the new one, and fix every
site that enumerates them — the generated artifact via its `workflow.src/`
fragment, never directly. State precedence wherever the new pattern overlaps an
existing one. Then assert **end-to-end reachability**: that the classifier emits
the label, and that the generated artifact carries it. A test asserting only the
doc table passes on dead wiring — that is
[[gate-header-claims-an-unimplemented-check]] one layer out, and a sibling of
[[survey-scoped-to-a-glob-misses-a-plugin]].
