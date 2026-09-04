---
name: size-the-effect-from-the-right-quantity
description: "Sizing an effect from the emitted bytes instead of the recorded artifact flipped 'too small to see' into 'a large effect is missing'"
metadata:
  node_type: memory
  type: feedback
---

Before concluding an effect is too small to measure, check you sized it from the
quantity that actually accumulates. Pick the wrong one and the conclusion
inverts — while reading perfectly plausibly.

Measured (#793): a hook emits **3 bytes** (`{}`) per fire. I wrote that this was
"~1 part in 10⁵ of a 144k-token prompt — a rounding error", and concluded the
measured null was unsurprising. Wrong quantity. The 3 bytes create a transcript
**record** measured at ~281 chars (~70 tokens), and it is the record that is
re-read every subsequent turn: 1,645 fires accumulate ~115k tokens, ~40% of an
average prompt time-averaged. The predicted effect was **large**, which makes its
total absence from the measurement the actual finding — evidence against the
issue's causal story — rather than an unremarkable null.

**Why:** the two framings license opposite next actions. "Too small to see" says
stop measuring and close the issue. "A large effect is missing" says the model of
*where the cost comes from* is wrong, and points at the next experiment. An
effect-size error is not a rounding detail; it is a conclusion.

**How to apply:**

- Ask **what persists**, not what was emitted. Bytes on stdout, a log line, a DB
  row, a cache entry — the thing that is re-read or re-sent is what accrues.
- Multiply by the real repetition (fires x turns resident), then compare against
  the same denominator the measurement uses.
- State the arithmetic in the artifact. My "~40%" hid a halving step (115k/144k
  is ~80%; 40% is the time-average of a linear accumulation) — review flagged it
  as unreproducible, correctly, since the number was load-bearing.
- A null result against a **large** predicted effect is a finding about the
  hypothesis. Say so, instead of explaining it away. Cross-ref
  [[issue-cause-may-be-falsified-by-measurement]] and
  [[measured-cause-may-invert-the-remedy]].
