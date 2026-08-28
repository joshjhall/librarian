---
name: the-correct-copy-is-the-one-under-test
description: When a helper exists in N unpinned copies, the fixture usually calls the one that is right — so the broken copy stays green forever
metadata:
  type: feedback
---

`is_test_file` exists in five copies across the repo. Exactly one pair is pinned
by `validate-shared-scanner-sync.sh`. While planning #622 I found
`check-lifecycle`'s **bash** copy uses the pre-#568 path-crossing glob
(`*/test_*.*`, where `*` crosses `/`) while its own Python twin is
basename-anchored — so real source under any `test_*/` directory is scanned by
one runtime and silently skipped by the other (filed as #836).

Every gate was green. `validate-python-ports.sh` even has a fixture containing
the exact divergent path, `src/test_helpers/production.py` — but it calls
**check-code-health's** implementation directly, which is the *correct* one. The
buggy copy has no direct test at all.

**Why:** a fixture is written next to the implementation someone was thinking
about, which is the one they just fixed. The unpinned sibling is invisible
precisely because nobody was thinking about it. "There is a fixture for this
predicate" is not "this predicate is tested" when the predicate has copies.

**How to apply:** when you find duplicated logic, do not stop at "do the copies
agree today?" — ask **which copy the existing tests actually execute**. Grep the
test corpus for the *file path* of each copy, not the function name. Then prove
the untested one behaviorally with an A/B pair that differs only in the
suspected input (identical file content in `src/helpers/` vs
`src/test_helpers/` was the whole reproduction).

Related: [[harden-one-knob-grep-every-sibling]],
[[parity-gate-hides-shared-defect]], [[test-defined-but-never-registered]],
[[self-skipping-test-hides-the-risky-branch]].
