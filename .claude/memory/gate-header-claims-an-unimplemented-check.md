---
name: gate-header-claims-an-unimplemented-check
description: A gate's own header/docstring can describe an assertion it never implements — grep for the enforcing code, don't trust the prose
metadata:
  type: feedback
---

A test gate's header comment is prose, and prose can describe an assertion the
gate does not actually make. **Before relying on a gate to cover something, grep
for the code that enforces it** — the identifier, the report tag, the
`run_test` line — rather than reading the header and believing it.

Worked example (#838). `tests/lint-language-table-sync.sh`'s header stated the
rule in two halves: an extension a scanner dispatches on "must map to the same
language key, **and** a comment marker it uses for a language must match the
normative one." Only the first half existed. Grepping `COMMENT_RE` in the gate
returned two hits, both inside header comments and neither in executable code.

The reason it went unnoticed is instructive and generalizes: the second half was
**unfalsifiable when written**. Phase 0 shipped the rule before any scanner
carried a comment-model subset, so there was nothing for it to check and no
fixture could have failed. The prose was aspirational and read as descriptive.

**Why:** an unimplemented assertion is worse than an absent one — it is a claim
of coverage that stops anyone from adding the real check.

**How to apply:** when a convention doc or ADR says "gate X enforces Y", confirm
by grepping the gate for Y's mechanism before depending on it. When you *create*
the first instance of the thing a dormant rule was written for, that is the
moment to implement the rule — it has finally become testable. Add it with an
anti-vacuity guard (the parser must find a non-trivial number of entries) and
prove teeth by mutating a value and watching it fail; a subset-comparison against
an empty normative table passes for free.

Related: [[comment-asserts-intent-not-code]],
[[surviving-mutation-may-be-a-real-no-op]],
[[test-defined-but-never-registered]],
[[deferred-work-may-be-doable-now]]
