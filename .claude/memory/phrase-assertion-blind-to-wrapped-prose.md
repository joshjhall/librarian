---
name: phrase-assertion-blind-to-wrapped-prose
description: A test asserting a multi-word prose phrase fails on wrapped markdown — the phrase is present, the newline sits mid-phrase, and the fix is to flatten whitespace, never to un-wrap the prose
metadata:
  node_type: memory
  type: feedback
---

An assertion matching a **multi-word phrase** against markdown fails the moment
that phrase wraps: `"never carry a memory's body"` is on disk as
`...memory's\nbody`, so a literal substring match reports it **missing** while it
is plainly there. Two failure directions, and both are bad:

- **False red now.** The gate fails on prose that satisfies it, and the tempting
  fix is to re-wrap the subject to suit the test — prose bent to formatting a
  gate happens to expect.
- **False green later.** Once the phrase is short enough not to wrap, the same
  assertion passes; a later reflow (or `dprint`) re-breaks it and the gate
  reports a violation that never existed. A phrase assertion is a contract
  anchored to **line-breaking**, which is exactly the
  [[prose-contract-anchored-to-prose]] defect one level down: that one anchors to
  *where* prose sits, this one to *how it wraps*.

This is the markdown twin of [[line-scanner-blind-to-wrapped-calls]] — same
silent-wrapping class, reached through prose rather than a `\` continuation.

**Why:** every phrase worth asserting is a sentence a writer will reflow. A gate
that breaks on reflow trains its maintainer to stop reflowing, or to delete the
assertion.

**How to apply:** flatten before matching — `tr '\n' ' ' | tr -s '[:space:]' ' '`
over the extracted region, then assert the phrase. Two riders learned the same
session: (1) **scope the region first**, because the harness prints the haystack
on failure and a flattened whole file buries the missing needle in 20 KB of
unrelated prose; (2) after switching, **mutate a reflow** — re-wrap the same
sentence differently and confirm the case stays green — otherwise you have only
proved the assertion matches, not that it survives what it was rewritten to
survive. Do not reach for `grep` with a `.*` bridge: markdown phrases carry `**`
and backticks a regex reads as operators, which is a second silent-miss stacked
on the first.
