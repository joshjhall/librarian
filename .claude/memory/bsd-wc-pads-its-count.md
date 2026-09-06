---
name: bsd-wc-pads-its-count
description: "BSD wc right-aligns its count to width 7, so an interpolated count silently corrupts a regex interval or evidence string"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0467e414-654d-4cf0-b23a-fa478104330b
  modified: 2026-09-06T20:57:09.594Z
---

BSD `wc` formats its count with `%7ju` — right-aligned to width 7 — where GNU
emits the bare number. So `n=$(... | wc -l)` is `"      6"` on macOS. Arithmetic
and `[ -ge ]` both strip leading blanks and are fine; **interpolation is not**.

Two live instances found together in #932:

- `loop-make-it-right` built a bounded-repeat interval from the count:
  `^.\{0,      0\}[^ ]` is **malformed**, matches nothing, so the "end of
  function" probe returned empty and every `def` fell through to a run-to-EOF
  fallback — 114 phantom HIGH rows where the correct answer was 0.
- `check-docs-organization` interpolated a count into evidence text:
  `has       6 files` vs python's `has 6 files` — a real TSV parity break.

**How to apply:** strip every `wc` count you interpolate
(`| tr -d '[:space:]'`), or avoid the fork — `_lead=${s%%[! ]*}; n=${#_lead}` is
fork-free, bash-3.2 clean, and immune to this *and* to BSD `sed` appending a
trailing newline to unterminated input (a second GNU/BSD split at the same
site). When surveying siblings, key the grep on the **mechanism** (any
unstripped `wc`), not the construct that happened to break — a survey scoped to
`\{0,` found one site; the mechanism found two. See
[[survey-scoped-to-a-glob-misses-a-plugin]].

Diagnosable on Linux without a BSD host: shim a `wc` that pads, and A/B. But
[[false-negative-from-env-restoring-path]] applies hard here — `BASH_ENV` put
the real `wc` back and three A/B runs read as "hypothesis wrong". Assert
`command -v wc` is the shim before trusting any result. Mutating the fix back to
the GNU spelling proves nothing ([[gnu-host-cannot-mutate-a-gnu-ism]]); mutate
to the *padded outcome* instead.
