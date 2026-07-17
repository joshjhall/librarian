---
name: worktree-new-test-coverage-matrix
description: The submodule/taint test coverage matrix for worktree-new.sh + config.sh repo_root() in validate-golem-scripts.sh
metadata: 
  node_type: memory
  type: project
  originSessionId: e6c9bc2f-b177-4c48-a7ad-4aff3664d9a0
---

`tests/validate-golem-scripts.sh` has a deliberate coverage MATRIX over
`worktree-new.sh` × submodule × tainted-git-env. Know the cells before adding
another so you fill a real gap, not a dup:

- `test_config_repo_root_submodule_superproject` (#324) — repo_root() UNIT, from
  inside submodule, placement logic (returns `<super>`, not `.git/modules`).
- `test_config_repo_root_submodule_superproject_scrubs_tainted_git_env` (#337) —
  repo_root() UNIT, submodule + PLAIN taint × super_root arm.
- `test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env`
  (#363, SHIPPED PR #366) — repo_root() UNIT, submodule + READONLY (`declare -rx`)
  taint × super_root arm; closes the readonly×super_root cell of the taint 2×2
  (the other three: #279 plain×common-dir, #328 readonly×common-dir, #337
  plain×super_root). Non-tautological-verified (neutering `env -u` fails it).
- `test_worktree_new_inits_submodules` (#325) — full script, from SUPERPROJECT
  root, asserts submodule POPULATION (not placement).
- `test_worktree_new_from_submodule_placement` (#338/PR #364) — full script,
  from INSIDE `<super>/mod`, asserts PLACEMENT at `<super>/.worktrees/issue-N`
  and nothing under `.git/modules`. The end-to-end analogue of the #324 unit test.
- `test_worktree_new_scrubs_tainted_git_env_for_mutations` (#328) — full script,
  from PLAIN (non-submodule) sandbox, taint scrub of the script's OWN mutations.
- `test_worktree_new_from_submodule_placement_under_taint` (#365, SHIPPED PR #373)
  — full script, from INSIDE `<super>/mod` AND under a tainted
  GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR toward a 3rd outer repo; fuses #338
  placement (worktree at `<super>/.worktrees/issue-45`, nothing under
  `.git/modules`) + #328 no-split-brain (branch ref in `<super>`, absent from
  outer). Closes the last uncovered cell of the matrix. Non-tautological-verified
  (neutering `unset $GIT_ENV_SCRUB_VARS` fails the branch-ref asserts). **Matrix
  now COMPLETE.**

Shared fixture: `_make_super_with_submodule <out-var>` (returns 2 → skip_test
when `submodule add` unavailable, 1 on hard fail). Tests that must `cd` into the
submodule subdir can't use `run_in` (it cd's to sandbox root) — hand-roll the
`env` invocation mirroring run_in's scrub/pins with a FULLY-LOCAL `out`/`rc`
pair, never the shared `RUN_OUT`/`RUN_RC` globals (breaking the pair trips the
conventions reviewer). Issue arg numbers in use: 31-36, 40, 41, 44, 45, 78, 79.
The git-env scrub var list is now single-sourced as `GIT_ENV_SCRUB_VARS` in
config.sh (#356/#367); the three callers `unset $GIT_ENV_SCRUB_VARS`.
See [[repo-root-submodule-superproject]].