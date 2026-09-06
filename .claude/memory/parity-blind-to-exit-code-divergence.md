---
name: parity-blind-to-exit-code-divergence
description: A bash<->python parity gate compares STDOUT, so a refusal path that emits nothing in both impls can diverge on exit code alone and pass green
metadata:
  type: feedback
---

A same-output parity gate cannot see a divergence that lives entirely in the
**exit code**. If a code path's job is to REFUSE — emit nothing on stdout, fail
non-zero — then both impls emit nothing whether they refuse or not, and the two
compare equal.

**Measured (#816).** `tests/validate-python-ports.sh` pins byte-identical TSV
between each `patterns.sh` (`PATTERNS_FORCE_BASH=1`) and its `patterns.py`. A
mutation changing the Python input-guard's `return 1` to `return 0` left all 45
tests green: bash exited 1, python exited 0, and stdout was empty for both. The
structural lint gate missed it too — the `return 1` sat inside a multi-line
expression the grep did not reach.

**Why it generalizes.** This is the sibling of
[[parity-gate-hides-shared-defect]] (both impls wrong the same way). That one is
about *agreement on a wrong answer*; this one is about a *dimension the
comparison never looks at*. Any assertion of the form "the two runtimes match"
is only as wide as the channel it compares.

**How to apply:** when adding a refusal / early-exit / fail-loud path to a ported
tool, add an assertion on the **exit code** in both runtimes — parity over stdout
will not cover it. Then mutate that specific `return`/`exit` and confirm a test
turns red. If a structural gate also claims to cover it, scope the pattern to the
lines between two stable anchors, or a multi-line spelling will slip past.
See [[mutation-round-finds-the-untested-rule]], [[measure-suppression-before-keeping-it]].
