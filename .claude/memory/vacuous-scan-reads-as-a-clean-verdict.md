---
name: vacuous-scan-reads-as-a-clean-verdict
description: A scanner handed the wrong input shape scans nothing and exits 0, so "zero findings" can mean "never looked" — assert the corpus was non-empty before trusting a clean result
type: feedback
metadata:
  node_type: memory
  modified: 2026-09-14T00:00:00.000Z
---

`check-okf-conformance`'s `patterns.py` takes a newline **file list** as argv[1].
Handed a path that lists nothing that exists, it scans nothing, prints a warning
to stderr, and **exits 0** with no findings — indistinguishable at a glance from
a genuinely clean corpus.

Measured on #934: probing whether a hand-built OKF §8 bundle validated clean, I
read "no rows" as proof and reported it to the operator as a verified fact. The
list was stale; the scan had covered zero files. The real answer was the
opposite — the bundle emitted a dangling row — and the decision built on top of
that reading had to be re-opened and re-escalated.

**Why:** a zero-row result has two causes that look identical in the output —
"nothing is wrong" and "nothing was examined" — and only one of them is a
verdict. The warning that distinguishes them goes to stderr, where a
`| grep`-shaped probe drops it. This is the silence-reads-as-a-pass shape
(#538/#571) arriving through the input rather than through the exit code.

**How to apply:** before trusting any clean scan, assert the corpus was
non-empty — the count of files actually read, not the count you passed in. The
repo's own harness does this: `validator_rows` in
`tests/lib/okf-migrate-sandbox.sh` publishes `OKF_LISTED`, and every caller
asserts it `-gt 0` **before** asserting zero rows. Do the same by hand when
probing at the shell, and never report a clean scan to a human without having
checked it. Related: [[absence-assertion-needs-a-leak-fixture]],
[[blocking-empty-is-not-nothing-to-fix]].
