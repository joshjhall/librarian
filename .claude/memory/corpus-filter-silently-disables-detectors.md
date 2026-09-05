---
name: corpus-filter-silently-disables-detectors
description: A scanner's file filter can make whole detector CATEGORIES unreachable — they report clean by construction; grep the detectors' own gating
metadata:
  type: reference
---

When wiring an existing scanner into a new caller, the **file filter you choose
is a silent capability switch**. Detectors gate on filename
(`if not _glob(path, "*.json"): return`), so a corpus of `**/*.md` makes every
`.json` / `.sh` / `workflow.js` detector return **clean by construction** — not
because the tree is clean. Zero rows from a category you never fed is
indistinguishable from zero rows because nothing is wrong.

This is the inert-gate shape reached through the **input** rather than the
runtime, and the usual guards miss it: an empty-corpus check passes (the list is
non-empty) and the scan exits 0.

**How to apply:** before trusting a scan's coverage, grep the scanner for its
per-detector gating (`_glob(path`, `endswith`, `case "$f" in`) and diff that
against your filter. Name the categories your corpus can never reach.

**Then measure both corpora before widening** — more coverage is not
automatically better. On #907: markdown-only = 11 rows, all genuine; broadened
to 192 files = 42 rows, and **all 31 additions were false positives** (a
destructive-command detector matching `rm -rf` inside *comments* and inside the
deny-list literals of the very guard that blocks those commands; an insecure-URL
detector flagging JSON Schema `$schema` draft-07 identifiers that are never
fetched). 31 FPs / 0 TPs is "not at this tier"
([[detector-needs-a-certainty-tier]]) — baselining false rows trains the reader
to ignore the ledger, and a ratchet is worth only as much as the baseline
someone will read.

Keeping the narrow scope is then legitimate, but it must be **stated, not
implied**: record the measurement where the filter lives, mark per-category what
is and is not reachable, and add a test that fails if the filter widens
(fixture files carrying content the excluded detectors *would* flag must produce
no findings). A deliberate scope limit and an accidental one look identical from
the outside. Related: [[gate-header-claims-an-unimplemented-check]].
