---
name: glob-star-is-not-more-of-the-same
description: "Widening [0-9][0-9]- to [0-9][0-9]*- does NOT mean 'two or more digits' — a glob * matches ANY characters, so it silently admits digits-then-arbitrary-text; enumerate the widths instead"
metadata:
  node_type: memory
  type: feedback
---

Extending a bounded character-class glob by appending `*` reads like "more of
the same class" and is not. `*` matches **any** characters, so widening
`[0-9][0-9]-${name}.sh` to `[0-9][0-9]*-${name}.sh` admits far more than a
third digit:

```text
$ find tests -name '[0-9][0-9]*-version.sh'
tests/10-notes-version.sh    <- digits, then TEXT
tests/10-utils-version.sh    <- the over-match a prior fix had closed
tests/100-version.sh         <- the only one intended
```

In #894 this re-opened, from the prefix side, exactly the false negative that
`sh_test_find_args_exact` had been hardened against on the suffix side: a short
generic stripped candidate (`version` from `ruff-version`) matched an unrelated
multi-segment fragment, silently marking an untested source as tested.

**Why:** a silently over-matching test-discovery glob suppresses a real
missing-test finding, which is the silence-reads-as-a-pass failure this repo
keeps filing issues about.

**How to apply:** enumerate the widths — `[0-9][0-9]-` plus `[0-9][0-9][0-9]-` —
so every character between the prefix and the anchored name is guaranteed a
digit. Bound the claim to what you enumerated: measure the tree (71 two-digit,
2 three-digit, nothing else) and say "two or three", never "two or more".
**Each width is its own literal glob, so each needs its own negative control** —
a `10-notes-<name>.sh` control cannot catch a regression confined to the
3-digit arm; verified by mutation that widening only the 3-digit globs back to
the `*` shorthand passed green until 3-digit twins were added. Same for the
suffix form `NNN-<name>-*.sh`, which survived being dropped outright until it
got a fixture.

The comment is what made it look safe: it asserted the `*` "can only ever
consume more DIGITS", an invariant the code did not have — see
[[comment-asserts-intent-not-code]]. Related:
[[fixture-must-express-the-divergent-case]],
[[mutation-round-finds-the-untested-rule]].
