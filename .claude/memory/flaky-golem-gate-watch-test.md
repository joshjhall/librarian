---
name: flaky-golem-gate-watch-test
description: "tests/golem-gate-watch.sh non-hermeticity — root-caused to GIT_DIR leak from push hook; fixed in PR #62"
metadata:
  node_type: memory
  type: project
  originSessionId: 3fe68c9e-e721-4106-9253-32d8429d669b
---

`tests/golem-gate-watch.sh` (a stage in `tests/run-all.sh`, so it gates
pre-push and CI) was **non-hermetic** and failed deterministically when run
from a real `git push` pre-push hook — even though it passed standalone, via
`bash tests/run-all.sh`, and via `lefthook run pre-push` from an interactive
shell.

**Root cause (found 2026-06-29, issue #56 / PR #62):** `git push` exports
`GIT_DIR` / `GIT_INDEX_FILE` / `GIT_WORK_TREE` etc. into the hook environment.
The test's `_run_once_snapshot` spins up a temp repo per case, but inherited
those vars — so `git init` and the gate-watch script's `repo_root` resolved to
the **outer** repo, the temp `feed.jsonl` was never read, and every assertion
failed on an empty snapshot. (The earlier hypothesis that it read a *sibling
golem's* live feed was wrong — it's the env leak, not cross-contamination.)

**Why:** the symptom looked like flakiness (passed on some invocations, failed
on others) only because `GIT_DIR` is present in the push-hook env but absent
elsewhere — so the same code passed or failed purely by how it was launched.

**How to apply / fix:** scrub the `GIT_*` vars with
`/usr/bin/env --unset=GIT_DIR --unset=GIT_INDEX_FILE …` for both the temp
`git init` and the gate-watch run subshell. Reproduce the failure locally with
`GIT_DIR="$(git rev-parse --git-dir)" bash tests/golem-gate-watch.sh`. General
lesson: any test that shells out to `git` in a temp repo MUST scrub `GIT_*`,
because pre-commit/pre-push hooks run with those exported. Related:
[[verify-squash-merge-landed]], [[release-process]].
