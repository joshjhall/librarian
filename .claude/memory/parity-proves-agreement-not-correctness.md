---
name: parity-proves-agreement-not-correctness
description: A byte-for-byte twin-parity assertion is blind to any defect both runtimes share — it proves the twins AGREE, never that either is RIGHT; assert content separately
type: feedback
metadata:
  node_type: memory
  modified: 2026-09-14T00:00:00.000Z
---

This repo's two-runtime model (python primary + bash fallback) is pinned by
byte-for-byte parity assertions, and it is easy to read a green parity suite as
"the pair is correct". It is not that claim. Parity is an assertion about the
RELATIONSHIP between the twins, so a defect present in BOTH is invisible to it
by construction.

Measured on #934, three times in one PR:

- An append-ordering defect wrote `c1, c2, c3` as `c1, c3, c2`. Both runtimes
  did it identically (each applies edits highest-line-first against a growing
  buffer), so the tree-parity fixture stayed green.
- An escaping defect decoded a literal `\n` in content into a real newline.
  Again identical in both, again invisible to parity.
- Only the third — an `awk -v` that ate the escape in the bash twin alone —
  actually diverged, and that is the one parity caught.

So the score for parity on that PR was 1 of 3, and the two it missed were the
ones a reviewer had to find by reasoning about the algorithm.

**Why:** two implementations derived from one design share the design's bugs.
The bash twin is usually written FROM the python one (or vice versa), so a
wrong idea is transcribed faithfully — which is exactly what parity measures as
success. Parity's real job is catching TRANSCRIPTION error, and it is good at
that; it was never a correctness oracle.

**How to apply:** for every behavior worth pinning, write an assertion about the
CONTENT — the actual bytes/order/values expected — in addition to the parity
case. When a bug is found in one runtime, fix and fixture it in both, but do not
let the parity case stand in for the content assertion. And when mutation-testing,
target the runtime the fixture actually drives: a mutation against an unexercised
runtime is indistinguishable from a passing one (on #934 a fixture drove only
the bash twin, so mutating the python file "passed" and proved nothing).

Related: [[parity-blind-to-exit-code-divergence]] is the same blindness on a
different axis (stdout compared, exit codes not), [[prescan-bash-python-equivalence]],
[[asymmetric-mutation-reads-as-untested]].
