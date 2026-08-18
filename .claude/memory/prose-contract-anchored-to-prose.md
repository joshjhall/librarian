---
name: prose-contract-anchored-to-prose
description: A gate pinning prose by heading pairs or sentence fragments blocks the very extraction it should survive — address blocks by a stable contract id instead
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 11132429-3014-4a1a-816f-781c2d7c5f7a
  modified: 2026-08-18T15:20:09.930Z
---

A prose-contract gate that extracts its region between two **literal strings** —
a heading pair, or worse an English sentence — is coupled to *where the prose
sits and how it is worded*, not to what it guarantees. Three failures follow,
none visible while the prose stays put:

1. **Moving a block breaks every assertion pinning it** though the guarantee is
   unchanged (#503: 81 assertions in one gate, 6 regions in another).
2. **Renaming a heading silently RE-ANCHORS** instead of failing — the region
   runs to the wrong end sentinel and swallows unrelated prose. This is why such
   gates accrete hand-maintained `MAX_LINES` bounds: the bound exists *only* to
   notice the mis-anchor.
3. **One block's heading becomes another region's end sentinel**, so an
   unrelated extraction expands a neighbouring gate's region as a side effect.

**Address a block by a stable id embedded in the prose** — `<!-- contract: <id> -->`,
resolved anywhere under the plugin tree (`extract_contract`, `tests/lib/harness.sh`).
The block can then be reworded, re-headed, or moved to another file with **no gate
edit**. Two properties make that safe: a missing or duplicated id **fails loud**
rather than yielding an empty region every `assert_contains` passes against, and
a delimiter must start the line so prose *explaining* the markers cannot truncate
a region. The `MAX_LINES` bounds delete with it — an id-delimited span cannot run
away.

Assert **operative tokens** — the literals a reader must obey (`AGNIX_CONFIG`,
`--fix-unsafe`, a log-line format) — never rationale sentences. Rationale should
be free to be rewritten; an enforced instruction should not.

**Why:** the coupling is invisible until someone tries to move the prose, at
which point a documentation change becomes a test rewrite — exactly when people
re-anchor assertions by hand and quietly lose coverage.

**How to apply:** before extracting prose a gate pins, check how the gate
addresses it. If by heading or sentence, convert to contract ids FIRST, and prove
the gate green **before and after** the move — that ordering is what makes the
extraction provably behaviour-preserving. Related:
[[gate-and-evidence-converge-tautology]], [[anchored-regex-tautological-test]].
