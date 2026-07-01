---
name: conform-scope-enum
description: "Commit scope is enum-restricted by .conform.yaml — fix(review): is rejected; use plugin/subsystem scopes"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2afd10d9-8b06-465b-8d18-950c1bc9ec98
---

This repo's `conform` commit-msg hook enforces a **fixed scope enum** (in
`.conform.yaml`): `dev-core`, `review-audit`, `workflow`, `marketplace`,
`manifests`, `scripts`, `skills`, `agents`, `hooks`, `tests`, `ci`,
`devcontainer`, `deps`, `docs`, `lefthook`, `gitignore`, `release`.

**Why:** the `ship-issue` skill tells golems to commit review fixes as
`fix(review): …` — but `review` is NOT in the enum, so that commit is rejected
by the commit-msg hook and the ship stalls.

**How to apply:** when committing review-cycle fixes (or any commit) in this
repo, map the generic skill scope to an allowed one — use the scope of the
files actually changed (`fix(workflow): …` for `plugins/workflow/**`,
`fix(tests): …` for `tests/**`, etc.), never `fix(review):`. See
[[flaky-golem-gate-watch-test]].
