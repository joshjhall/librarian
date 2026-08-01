---
name: wall-timeout-decision-helper
metadata: 
  node_type: memory
  type: project
  originSessionId: 84c3feac-4129-4741-b12c-272d2efa8deb
---

Issue #327 wanted the ship-issue review harness wall-time bound (#307's
`LIBRARIAN_WORKFLOW_WALL_TIMEOUT`, prose in pre-ship-validation.md /
ci-review-protocol.md / ship-protocol.md) made "mechanically enforced, not
prose" — its acceptance criterion 1 said "TaskStop a hung review WITHOUT relying
on model-chosen polling."

**That literal criterion is impossible** under [[two-runtime-model]]: `Workflow`
/ `TaskOutput` / `TaskStop` are model-runtime tools; a bundled shell script runs
sandboxed and has no handle to kill a Workflow task. Full mechanical enforcement
needs a Workflow-tool/runtime change, not a plugin edit.

**What shipped (fix on branch feature/issue-327, L3 run):** mechanize the
*decision*, not the kill — new bundled `plugins/workflow/scripts/workflow-wall-timeout.sh`
(bash-only, no python port like `recover-journal-partials.sh`) with a `check
--elapsed-min N --level L --extensions-used K` subcommand returning
`verdict=continue|extend|stop|checkpoint` + ceiling/next_deadline/extensions_used.
Reads the same `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (20) / `_MAX_EXTENSIONS` (1)
env vars. The 3 prose sites now CALL it each poll instead of the model
re-deriving threshold arithmetic (the cap-drift that wedged golem-266/252/263).
Model still issues the actual TaskStop — on the helper's verdict. Exact mirror of
how [[autonomy-resolver-script]] replaced the prose L1-L4 table. Test gate:
tests/validate-workflow-wall-timeout.sh (30 cases), wired into run-all.sh.

**Shipped as PR #339** (parked for human merge, NOT auto-merged — L3 dead-end:
CI green but review can't reach `clean` because AC1/AC3 are architectural, not
defects). Pre-PR review caught one REAL bug I introduced: `is_nonneg_int`
accepted leading-zero numerals → bash reads `030` as OCTAL (silent wrong ceiling
48≠60) and `08` crashes past exit-2. Fixed by rejecting leading zeros (`0` alone
still valid) + a `--extensions-used > MAX_EXTENSIONS` fail-loud guard + AC3
bounded-poll-loop fixture. **Lesson: any digit string reaching `$(( ))` / `[ -lt
]` must reject leading zeros, not just `[!0-9]`.** NOTE: first commit says "Closes

# 327" but PR body says "Refs" (AC1 only partially satisfiable) — flagged for the

human merger; likely keep #327 open for the enforcement follow-up.

**Why:** re-opening this class = a model deep in review interpreting prose caps.
**How to apply:** when an issue asks for "mechanical enforcement" of a
model-behavior bound, the achievable version is a called decision-helper +
regression test; the tool orchestration stays with the model by runtime
necessity — say so honestly in the PR rather than claiming criterion 1 met.

Out of scope (PR notes as follow-ups): orchestrator backstop for a golem with
committed work but no PR (Proposal 2); rebuild root-owned /opt/librarian to a

## 307-carrying build (Proposal 3 / Layer 2, needs sudo rsync)
