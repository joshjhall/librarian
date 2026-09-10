---
name: anchor-binds-to-grep-n-prefix
description: A `^`-anchored filter applied to `grep -n` output binds to the line-number prefix, not the line — the exclusion silently never fires
type: feedback
metadata:
  node_type: memory
  type: feedback
---

A second-stage filter over `grep -n` output sees `NNN:` before the content, so a
`^`-anchored pattern written against the *source line* never matches. The filter
does not error — it just stops excluding, and every row it was meant to drop is
emitted.

This bites hardest in a **dual-runtime port** where the twin has no such prefix:
the Python half applies its regex per-line and excludes correctly, the bash half
silently does not, and the two diverge on exactly the rows the exclusion exists
for. Spell the prefix (`^[0-9]+:[[:space:]]*…`) in any anchored filter downstream
of `-n`.

**Why:** ERE has no negative lookahead, so an exclusion becomes a second
`grep -vE` stage — and that stage's input is the *formatted* output, not the
file. The anchor still matches something, which is why it fails silently rather
than loudly.

**How to apply:** when adding an exclusion to a `grep -n` pipeline, run both
runtimes over the real corpus and diff before trusting it. Found in #842, where
the sole corpus false positive survived on the bash runtime only —
[[parity-blind-to-exit-code-divergence]] is the sibling shape, and
[[grep-q-under-pipefail-inverts-a-match]] is the other `grep`-stage trap in the
same pipelines.
