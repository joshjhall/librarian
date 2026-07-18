---
name: worktree-new-test-coverage-matrix
description: The submodule/taint test coverage matrix for worktree-new.sh + config.sh repo_root() in validate-golem-scripts.sh
metadata: 
  node_type: memory
  type: project
  originSessionId: e6c9bc2f-b177-4c48-a7ad-4aff3664d9a0
  modified: 2026-07-18T06:51:21.976Z
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

Per-scrub-VAR behavioral coverage (distinct from the submodule matrix above) —
each of the 14 `GIT_ENV_SCRUB_VARS` names now has a DISCRIMINATING live-taint
test, not just the static list-equality assertion in
`test_config_git_env_scrub_vars_single_source`. #355/PR #375 did
GIT_CONFIG_COUNT/PARAMETERS injection + GIT_CEILING_DIRECTORIES. #376 (PR #386)
closed the last four: GIT_CONFIG_GLOBAL/SYSTEM via a config-FILE injection
(shared `_assert_config_file_injection_scrubbed` — NO repo-local seed: global/
system scope loses to repo-local and would shadow the injection, a vacuous-test
trap I hit) and GIT_CONFIG_NOSYSTEM/GIT_DISCOVERY_ACROSS_FILESYSTEM via an
invalid-bool (`=notabool`) availability taint (shared `_assert_bool_var_scrubbed`
— bare git fatals rc128 "bad boolean", `_repo_root_git` runs clean; the rc128+
substring coupling to git's wording is the #387 follow-up). #376 also added the
mutation-level `test_worktree_{new,rm}_scrubs_git_config_injection_for_mutations`
(full script under GIT_CONFIG_COUNT core.hooksPath → a failing
`reference-transaction` hook seeded by `_seed_failing_ref_hook`; a NONEXISTENT
hooksPath does NOT discriminate — git silently proceeds — so the hook must exist
and actively fail). Every #376 test proven non-vacuous by neutering
`_git_env_scrub_names` to emit nothing and confirming all 6 FAIL.

Shared fixture: `_make_super_with_submodule <out-var>` (returns 2 → skip_test
when `submodule add` unavailable, 1 on hard fail). Tests that must `cd` into the
submodule subdir can't use `run_in` (it cd's to sandbox root) — hand-roll the
`env` invocation mirroring run_in's scrub/pins with a FULLY-LOCAL `out`/`rc`
pair, never the shared `RUN_OUT`/`RUN_RC` globals (breaking the pair trips the
conventions reviewer). Any helper using `printf -v "$__out"` must name its
internal locals OFF the caller's out-var (e.g. `hdir` not `hooks`) or it shadows
and clobbers the caller's var — same pitfall `_make_super_with_submodule`'s `sup`
sidesteps; I hit it in `_seed_failing_ref_hook`. Issue arg numbers in use: 31-36,
40, 41, 44, 45, 76, 77, 78, 79. The git-env scrub var list is now single-sourced
as `GIT_ENV_SCRUB_VARS` in config.sh (#356/#367); the three callers
`unset $GIT_ENV_SCRUB_VARS`.
See [[repo-root-submodule-superproject]].
