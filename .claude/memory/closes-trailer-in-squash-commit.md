---
name: closes-trailer-in-squash-commit
description: "Editing a PR body's \"Closes #N\"→\"Contributes to #N\" does NOT stop auto-close if the golem's squash-commit body also carries a Closes trailer; the merge commit message closes the issue"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4a569e6e-ef19-4017-ab95-d5f8dfddb610
  modified: 2026-07-21T03:17:19.613Z
---

On the 2026-07-20 orchestrate run the operator chose **Contributes to #411** (keep

# 411 open, let follow-up #451 close it). I edited PR #453's **body** `Closes #411`

→ `Contributes to #411` and confirmed `closingIssuesReferences` went empty — then
merged, and **#411 closed anyway**. Root cause: the golem's `/ship-issue` had
written its own `Closes #411` trailer into the **squash-commit message body**
(a separate surface from the PR description). GitHub honors closing keywords in
the **merge commit message**, so the squash trailer auto-closed #411 regardless of
the PR body. Fix was to `gh issue reopen 411` + comment the correct state.

**Why:** `Closes #N` can live in TWO places — the PR description AND the commit
message. `gh pr edit --body` only touches the first. A squash merge concatenates
the commit body into the merge commit, so a `Closes` trailer there still fires.

**How to apply:** to convert Closes→Contributes on an already-created golem PR,
fix **both** surfaces before merging: (1) `gh pr edit N --body-file` for the PR
description, AND (2) check the head commit body (`git log origin/main..HEAD
--format=%B` in the worktree, or `gh pr view N --json commits`) for a `Closes`/
`Fixes`/`Resolves #N` trailer — if present, either amend the commit or override
the squash-merge commit message at merge time (`gh pr merge N --squash
--body "..."` / `--subject`). Verify post-merge with `gh issue view N --json
state`; reopen + comment if it closed wrongly. Extends
[[umbrella-issue-closes-vs-contributes]] (that memory covers the decision; this
covers the two-surface mechanics that defeat a body-only edit) and
[[verify-squash-merge-landed]] (always verify post-merge state).
