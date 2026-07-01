---
name: pre-review-gates-project-root
description: pre-review-gates.sh resolves _PROJECT_ROOT via git rev-parse; tests of its scan categories need a git-scrubbed sandbox
metadata:
  node_type: memory
  type: project
  originSessionId: 13da0b8e-0e9a-47ce-951c-0c33f7cb4d30
---

`plugins/workflow/skills/ship-issue/pre-review-gates.sh` resolves
`_PROJECT_ROOT` via `git rev-parse --show-toplevel` to locate both
`.claude/pre-review.yml` (the project skip-policy override read by
`load_test_skip_policy`) and the repo-rooted `tests/` tree used by the
`missing-test-file` scan.

Consequences for testing it (see `tests/validate-pre-review-gates.sh`, added for
issue #83, PR #120):

- The skip-policy / project-root-sensitive cases must run the real script inside
  a fresh `git init` sandbox with the `GIT_*` hook env scrubbed
  (`/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"`), or a leaked `GIT_DIR` under a
  `git push` pre-push hook pins `_PROJECT_ROOT` to the OUTER librarian checkout.
  Same root cause and scrub pattern as [[flaky-golem-gate-watch-test]] and
  `tests/validate-golem-scripts.sh`.
- Fixtures must be `.py`/`.js` — `test-skip-patterns.default` blanket-skips
  `*.sh`/`*.md`/config types, so a `.sh` fixture would be silently skipped and
  the detector would never fire.
- Skip-policy override fixtures should use a pattern NOT in the defaults (e.g.
  `generated/**`) so the assertion proves the project YAML is honored, not the
  bundled defaults; mutation-check by removing the YAML (both fixtures should
  then flag) to prove non-vacuity.
