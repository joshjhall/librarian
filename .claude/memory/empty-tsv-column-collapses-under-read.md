---
name: empty-tsv-column-collapses-under-read
description: TAB is IFS whitespace, so `read` merges consecutive tabs and an empty column shifts every later field left
metadata:
  type: feedback
---

An empty field in a TSV row does not survive `read`. TAB is IFS whitespace, so
consecutive tabs collapse into one separator and every later field shifts left —
silently, with no parse error anywhere.

**Why:** measured in #890 — a registry row written with no pid put the
DESCRIPTION into `$pid`, which the reaper then handed to `kill -0`. The writer
and the reader each look correct read in isolation; nothing logs a delimiter
problem, so the corruption only shows up as a nonsense downstream action. This is
the same shape as [[parity-gate-hides-shared-defect]]: both halves agree, and are
both wrong.

**How to apply:** emit a sentinel (`-`) for any absent TSV field, never an empty
one. In the test, assert BOTH that `NF` equals the declared field count AND that
the LAST field still holds its value — an NF check alone passes while the row is
shifted, and a last-field check alone passes on a row that is short.
