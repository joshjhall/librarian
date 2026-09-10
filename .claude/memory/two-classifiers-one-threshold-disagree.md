---
name: two-classifiers-one-threshold-disagree
description: Two code paths classifying against the same constant disagree at its exact value; one report then contradicts itself
metadata:
  type: feedback
---

When two places classify the same quantity against one shared constant, they
will eventually disagree **at the constant's exact value** — and the disagreement
is invisible everywhere else.

Measured (#870): `cmd_timing` bucketed a leader's gap with half-open intervals
(`low <= gap < high`), putting `gap == 300` in the `300-600s` row — past the TTL.
Its own attribution loop, twenty lines down, used `elif gap > CACHE_TTL_SECONDS`,
a strict `>`, which called the *same spawn* in-TTL. One report contradicted
itself at the boundary, in a tool whose stated premise is being hand-checkable.

**Why:** each path reads correct in isolation; only the boundary case differs, so
no ordinary fixture and no real corpus surfaces it (an exact 300.000s gap is
rare). It survives review unless someone compares the two comparisons directly.

**How to apply:** when a constant is consumed by more than one classifier, pick
one convention (half-open is the usual choice) and make every site match it
literally — then encode the convention in the *output labels* (`>= TTL` /
`< TTL`, not `> TTL` / `<= TTL`) so a reader can see which side the boundary
falls on without opening the source. Add a fixture at exactly the constant, since
that is the only input where the paths differ. Grep for every site reading the
constant, not just the one you touched — [[harden-one-knob-grep-every-sibling]].

The same sweep applies to prose: the docstring and the verification doc both
described the metric, and the wrong description had been copied into both. A
reviewer flagged only one. See [[comment-asserts-intent-not-code]].
