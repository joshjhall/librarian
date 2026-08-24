---
name: execute-the-workflow-step-dont-grep-it
description: "A CI `run:` block's regressions are re-ORDERINGS, which every string grep survives — slice the real block and execute it under a stub PATH"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 956ca71e-7925-484d-98d4-227c314aa2a5
  modified: 2026-08-22T23:06:01.270Z
---

To test a GitHub Actions `run:` block, `awk`-slice the step's real body out of
the `.yml` (by block-scalar **indentation**, not by anchoring on the next
`- name:`) and execute it under `bash -e` with `PATH` pinned to a stub dir whose
fake tools take their exit codes from the environment.

**Why:** the regressions that matter in those blocks are **moves**, not
deletions. #734's fix was folding `agnix --version` *into* an `if` condition;
hoisting it back into the `then` branch leaves every searched string present and
in the same order, so a grep-based gate stays green while the job fails under
`bash -e`. `tests/lint-agnix-clean.sh` greps that file and cannot see it.
Copying the body into the test instead is worse than nothing — the copy passes
forever while the original drifts.

**How to apply:** `bash -e` in the child is load-bearing, not hygiene — it is
the exact condition that distinguishes the fixed shape from the regression.
Unset `BASH_ENV` and scrub git's hook env in every child, or the devcontainer's
`/etc/bash_env` resets `PATH` and the REAL tools outrank the stubs. The
extractor must **fail loud** on an absent or over-grown region: a silently empty
slice makes every assertion pass vacuously, so assert non-emptiness AND that the
body carries the marker that makes the case meaningful (`npm install -g`,
`present=`). Prior art with the same discipline:
`tests/validate-agnix-helpers.sh` (slices gate helpers),
`tests/validate-lint-gates.sh` (slices `run_stage` and post-create's install
decision).
