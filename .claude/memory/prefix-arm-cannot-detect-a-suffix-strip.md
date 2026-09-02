---
name: prefix-arm-cannot-detect-a-suffix-strip
description: A fixture aimed at a permissive arm of a case table cannot detect a normalization the strict arms need; pick the input where the arms disagree
metadata:
  type: feedback
---

When a `case` table mixes **strict** arms (`github.com | *.github.com`) with
**permissive** ones (`ghe.*`), a fixture built on a permissive arm cannot test
any normalization applied before the match — the permissive arm matches with or
without it, so the mutation survives.

**Measured (#810):** the code strips a `:port` before matching, and the test used
`ghe.example.com:8443`. `ghe.*` is a prefix match, so it matched the ported host
either way and dropping the strip changed nothing. Only a fully anchored arm
diverges: `github.com:8443` matches nothing until the port is gone. Re-keying the
fixture to `github.com:8443` killed the mutation immediately. The source comment
had cited the same misleading `ghe.` example, so the prose was reinforcing the
untestable choice.

**How to apply:** before writing the fixture, ask *which arm changes its answer
when this normalization is removed* — usually the strictest one — and build the
input there. Then mutate to confirm. Generalizes
[[fixture-must-express-the-divergent-case]] to the case-table shape, and pairs
with [[asymmetric-mutation-reads-as-untested]]: an arm-by-arm table needs an
arm-by-arm fixture, since neutering one arm alone otherwise survives.

Anchoring note worth keeping: a bare `*github.com` suffix glob also matches
`evil-github.com`; anchor on a dot boundary (`github.com | *.github.com`). A
self-hosted arm has no fixed suffix, so it stays a prefix match — say so in a
comment rather than letting a reader assume full anchoring.
