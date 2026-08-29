---
name: detector-needs-a-certainty-tier
description: Before implementing a detector an issue names, measure its hit rate against the scanner's declared certainty — the honest answer may be "not at this tier"
metadata:
  type: feedback
---

An issue that names a detector idiom is stating a *hypothesis*, not a
specification. Before implementing it, **count the idiom in a real corpus of that
language and compare against the scanner's declared certainty**, because a
scanner with one global `CERTAINTY` has no way to carry a noisy detector.

Worked example (#838, Rust `empty-handler`). The issue named two swallow idioms:
`let _ = …` and an empty `Err(_) => {}`. Measured on the Rust available on the
machine: **723** `let _ =` lines against **2** empty `Err(_)` arms — and sampling
the `let _ =` lines showed they were overwhelmingly *deliberate*: `write!` into a
`String` (infallible by construction), `let _ = guard;` to extend an RAII
lifetime, `let _ = param;` to silence an unused warning. `check-code-health`
emits `HIGH` at declared confidence >= 0.9 with no per-detector tier, so shipping
it meant ~721 false positives to reach 2 true ones.

**Why:** a detector that cannot hold its scanner's tier degrades every consumer
of that scanner — the finding stream is read as high-confidence by definition.

**How to apply:** when an issue names a detector, grep the idiom across whatever
real source of that language you can reach and get a count *before* writing the
arm. Then check the scanner's `CERTAINTY` constant and its contract's declared
confidence. If the measured precision cannot support that tier, the options are
"wrong tier" or "not yet" — say which, in the contract and in a boundary fixture
that pins the decision, so adding it later is conscious rather than accidental.
Shipping it anyway to satisfy the issue's letter is the wrong trade.

The same measurement also tells you when a detector IS fine: `Command::new` will
match `clap::Command::new`, but `check-lifecycle` emits `MEDIUM` candidates for
an LLM pass to confirm, so that noise is within its declared tolerance. The tier
is what makes the difference, not the noise alone.

Related: [[pinned-behavior-may-be-a-bug-report]],
[[issue-cause-may-be-falsified-by-measurement]],
[[measure-suppression-before-keeping-it]]
