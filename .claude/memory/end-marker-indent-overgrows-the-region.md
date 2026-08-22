---
name: end-marker-indent-overgrows-the-region
description: "A delimiter-terminated region fails ASYMMETRICALLY — a moved START marker errors loud, a moved END marker silently swallows the following text"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c5ce24e2-e77c-45fa-a057-bc727ea834d8
  modified: 2026-08-22T06:53:00.095Z
---

Any extraction bounded by a start and an end delimiter has two failure modes,
and only one of them is loud:

- **Start delimiter moves/breaks** → the extractor cannot find the region and
  fails loudly. Fine, if misleadingly worded.
- **End delimiter moves/breaks** → the region does not terminate. It
  **over-grows** into whatever follows, and every `contains`-style assertion
  still passes, because a bigger region still contains its tokens.

Measured on #737 against `extract_contract` (tests/lib/harness.sh), whose
terminator is `index($0, "<!-- contract:") == 1`: indenting an end marker by two
spaces left all six tests PASSING. A tamper check does not save you here —
`assert_contract_carries` proves the token is genuinely present, not that the
region ended where it should.

**Why it hides:** assertions on a region are almost always
existence assertions. Existence is monotonic in region size, so every check gets
*easier* to satisfy as the region grows. The failure enlarges the haystack rather
than removing the needle.

**How to apply:** pin the **end** delimiters too, not just the ids naming the
regions — same shape as the start check. Where the extractor requires
column-0 delimiters, assert that explicitly. And test it: indent the end marker
and confirm something fails. Region-bounding assertions (a length or exclusion
check — "the region must NOT contain the text after it") are the other half.

Related: [[prose-contract-anchored-to-prose]] for why ids beat headings in the
first place; [[gate-and-evidence-converge-tautology]] for the sibling shape where
a check gets easier to satisfy for a different reason.
