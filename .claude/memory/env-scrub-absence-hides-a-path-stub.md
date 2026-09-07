---
name: env-scrub-absence-hides-a-path-stub
description: A test that sabotages via a PATH stub must unset BASH_ENV, or a profile re-sources and restores PATH and the stub is silently discarded
metadata:
  type: feedback
---

Any test whose mechanism is **a stub earlier on `PATH`** must run under
`/usr/bin/env -uBASH_ENV`. When `BASH_ENV` points at a profile (this
devcontainer sets `/etc/bash_env`), bash re-sources it and **restores `PATH`**,
so the stub is discarded before the subject runs. The real binary answers, the
sabotage never happens, and the assertion fails hunting for an effect that had
no reason to appear — or worse, passes vacuously.

**Why:** it bit twice in one session. First in a #946 test, where the failed
attempt was misread as "this branch is untestable" ([[untestable-is-a-claim-about-your-search]]).
Then in `tests/validate-prose-budget.sh`, where it had been latent all along and
**blocked every push from the devcontainer** — while **CI passed the same commit**,
because the runner sets no `BASH_ENV`. That asymmetry is why it survived: the
gate is green in the place everyone looks.

**How to apply:** grep a suspect test for `PATH="$stub` with no `-uBASH_ENV`
nearby. Confirm the stub is actually reached — `command -v <tool>` inside the
same invocation — before trusting a red or green result from it. Note the #932
sweep converting `env --unset=` to `-u` could not catch this class: the defect
is an **absent** env scrub, not a misspelled one, so a lint that rewrites
existing scrubs sees nothing. Prove the fix by mutation: remove the flag and
watch the failure return. Related: [[the-correct-copy-is-the-one-under-test]].
