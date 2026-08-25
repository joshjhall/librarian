---
name: concat-boundary-defeats-phrase-matcher
description: "A regex over a JS string built from concatenated literals silently stops matching when a phrase straddles a ' + ' join — collapsing whitespace is not enough"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: af6b1b7a-db5d-4281-8295-44415867b420
  modified: 2026-08-25T03:47:39.657Z
---

When asserting that a **phrase** appears in a JS string constant built by
concatenating adjacent literals (`'...' + '...'`), splice the joins out **before**
collapsing whitespace:

```js
const text = src.replace(/'\s*\+\s*'/g, "").replace(/\s+/g, " ")
```

`.replace(/\s+/g, " ")` alone is the tempting half-fix and it is not enough — it
leaves the quote-plus-quote artifact sitting mid-phrase, so a matcher for
`/Do NOT survey the repo/` fails against source that plainly contains that
sentence, split as `'...Do NOT survey ' + 'the repo for...'`.

**Why it matters beyond the immediate fix:** the failure is *position-dependent*
and therefore latent. A matcher whose phrase happens to sit inside one literal
today passes, and silently stops matching when someone re-wraps the prose for
line length — a formatting change, reviewed as cosmetic, that quietly disarms a
gate.

The same session (#785) produced the sibling trap in the *other* direction: the
slice feeding that matcher was end-anchored to a neighbouring comment's wording
(`indexOf("\n// \`sanitize\`")`). Re-word that unrelated comment and `indexOf`
returns -1, which slices to end-of-file — and the content assertions still pass,
because the phrases are in the file either way. The window silently widens to
whole-file matching with nothing failing. **Anchor a slice to the construct's own
terminator** (the next top-level `const`), and **assert the boundary was found**
rather than absorbing a -1.

Both are the same shape: an extraction step degrading quietly while the
assertions on top keep reporting green. Test what the extractor produced, not
just what the assertion concluded ([[absence-assertion-needs-a-leak-fixture]]).

Related: [[prose-contract-anchored-to-prose]],
[[escaped-fixture-cannot-self-match]],
[[end-marker-indent-overgrows-the-region]].
