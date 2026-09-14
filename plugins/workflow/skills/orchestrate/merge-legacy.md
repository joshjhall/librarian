# Orchestrate — Legacy Merge & Sync (OPT-IN)

Companion to `orchestrate/merge-protocol.md`, split out of it in #973 when that
file passed its prose budget. It carries every **[OPT-IN LEGACY]** section of the
merge protocol: sync-point tracking, squash-vs-merge-commit policy, the
local-merge review protocol, the sync protocol, agent checkpoint context, and the
legacy local-merge phases.

The seam is one the file already marked on every heading. The default topology is
**PR-per-golem**, where a golem's own `/workflow:ship-issue` merges its PR and the
orchestrator never merges golem branches into its own — so none of this runs
unless the operator has deliberately opted into the local-merge topology. Keeping
it beside the LIVE sections meant every reader of the live conflict-classification
rules paged past ~260 lines that do not apply to them.

**The LIVE sections stay in `merge-protocol.md`**: conflict classification for
cross-PR rebase, integration-train sequencing + CI-subset policy, and test-runner
detection.

## Sync Point Tracking [OPT-IN LEGACY]

Use `git merge-base` to track where agent branches diverged from the current
branch. This is the foundation for determining what's new.

```bash
# Find divergence point
MERGE_BASE=$(git merge-base HEAD <agent-branch>)

# List new commits on agent branch
git log --oneline "$MERGE_BASE"..<agent-branch>

# Count new commits
git rev-list --count "$MERGE_BASE"..<agent-branch>

# Check if already fully merged (0 = merged)
git rev-list --count "$MERGE_BASE"..<agent-branch>
```

After a successful merge, the merge-base advances automatically — no manual
bookkeeping needed. Subsequent `/workflow:orchestrate status` calls will show 0 pending
commits for that agent.

---

## Squash vs Merge Commit [OPT-IN LEGACY]

| Strategy                   | Pros                                                            | Cons                                                  |
| -------------------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| **Merge commit** (default) | Preserves full agent history; easy to trace what each agent did | More commits in log; noisier `git log --oneline`      |
| **Squash**                 | Clean single commit; ideal for small/focused agent tasks        | Loses individual commit granularity; harder to bisect |

**Recommendations:**

- **Use merge commit** (default) when:

  - Agent made multiple logical changes worth preserving
  - You may need to bisect within the agent's work later
  - Traceability of agent contributions matters

- **Use squash** when:

  - Agent work is a single logical unit (one feature, one fix)
  - Agent made many WIP/fixup commits
  - You want a clean linear history

The user can request squash via `/workflow:orchestrate merge <N> --squash` or by asking
for a squash merge in natural language.

---

## Review Protocol [OPT-IN LEGACY]

In the default PR-per-golem topology, per-PR review is the **golem's** job (the
`/workflow:ship-issue` adversarial review loop — the **Workflow tool** with
`ship-issue/workflow.js`, Step 3.5 item 6). This section applies only after a
legacy local merge (`/workflow:orchestrate review`), reviewing the merged changes for
correctness and quality.

### Review Scope

Review **only the merge commit diff** — not the entire file:

```bash
# For the most recent merge commit
MERGE_COMMIT=$(git log -1 --merges --format='%H')

# Diff of just the merge commit (changes introduced by the merge)
git diff "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"

# Files changed in the merge
git diff --name-only "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"
```

### Agent Dispatch Order

1. **`code-review` harness** — always run first, via the `Workflow` tool on the
   `path=` printed by `${CLAUDE_PLUGIN_ROOT}/scripts/harness-stage.sh stage
   code-reviewer` (the tool refuses a `scriptPath` outside the session cwd,
   #973). It reviews the merge diff for
   bugs, security issues, performance problems, and style violations as a
   parallel barrier under a shared budget, with a judge-panel rescore of each
   finding's certainty before merge. **Bound this invocation in wall-time
   (#224)** — it fans out reviewer subagents; invoke it as a background task with
   the caller-side timeout (a timed-out review is **partial**, never clean). See
   `mode-protocol.md` § *Bounding a Workflow invocation in wall-time*.
1. **`test-writer` agent** — dispatched only if the code-review findings
   indicate missing test coverage or if new public APIs were introduced
   without tests.

### Correction Commit Convention

All review fixes go into a **single correction commit** per review cycle:

```text
fix(review): {summary of corrections}

{bullet list of changes made}

Reviewed-by: orchestrate Phase 3
```

- One commit per review — do not create multiple fixup commits
- The `Reviewed-by` trailer provides traceability

### What NOT to Auto-Fix

Review should flag but **not automatically change**:

- **Architectural changes** — restructuring modules, changing abstractions
- **API deletions** — removing public interfaces or exported symbols
- **Dependency changes** — adding, removing, or upgrading dependencies
- **Configuration changes** — altering build configs, CI pipelines, env vars

These require user confirmation before modification.

---

## Sync Protocol [OPT-IN LEGACY]

Superseded by PR-per-golem (golems rebase their own PR branches onto base via
Phase R). This one-way orchestrator → agent-branch sync applies only to the
legacy local-merge path, pushing the latest orchestrator state into all agent
branches so they start their next task from a consistent baseline.

### Sync Direction

**Orchestrator → agent branches** (one-way). The orchestrator branch is the
source of truth after merges and reviews.

### Merge Order

Sync agents sequentially in natural order:

```bash
# agent01, agent02, agent03, ...
for branch in $(git branch --list 'agent*' | /usr/bin/sort); do
    # sync logic per branch
done
```

### Conflict Handling

Attempt an auto-merge. If conflicts arise, **abort and skip** that branch:

```bash
git checkout <agent-branch>
git merge <orchestrator-branch> -m "sync: merge orchestrator updates"

# If conflicts:
git merge --abort
# Log the skip, continue to next agent
```

Skipped agents will pick up changes on their next `/workflow:orchestrate sync` or when
the orchestrator merges their work (Phase 2) and syncs again.

### Post-Sync Verification

After syncing each branch, verify the merge-base advanced:

```bash
# Merge-base should now equal or be ahead of the previous merge-base
NEW_BASE=$(git merge-base <orchestrator-branch> <agent-branch>)
```

### Label Cleanup

After a successful sync, remove in-flight status labels from issues
associated with synced agent branches (the work has been fully integrated):

```bash
# GitHub
gh issue edit {N} --remove-label "status/commit-pending" --remove-label "status/in-progress"

# GitLab
glab issue update {N} --unlabel "status/commit-pending" --unlabel "status/in-progress"
```

### Return to Orchestrator

Always return to the orchestrator branch after sync completes:

```bash
git checkout <orchestrator-branch>
```

---

## Agent Checkpoint Context [OPT-IN LEGACY]

Used by the legacy local-merge review path. (In PR-per-golem, the golem carries
its own checkpoint and the human reviews the PR.) When reviewing agent work
after a `/clear`, the orchestrator can read the
agent's checkpoint from their JSON state file for context. This is especially
useful when the agent's conversation history is no longer available.

### Reading Agent Checkpoints

Agent state files live in the agent's worktree at
`.claude/memory/tmp/next-issue-{N}.json`. After merging an agent's work, check
if a state file exists with checkpoint data:

```bash
# From the agent's worktree directory. Exclude the singleton
# next-issue-queue.json — it is a dependency-queue record, not a per-issue
# checkpoint, and has none of the checkpoint fields read below.
for f in .claude/memory/tmp/next-issue-*.json; do
  case "$f" in */next-issue-queue.json) continue ;; esac
  cat "$f" 2>/dev/null
done
```

The `checkpoint` object contains:

- `key_decisions` — non-obvious choices the agent made (context for review)
- `files_modified` — what the agent changed (scope for review)
- `files_planned` — what the agent intended to change (completeness check)
- `warnings` — things the agent flagged for attention
- `next_action` — what the agent expected to happen next

### Using Checkpoint in Review

When dispatching the `code-reviewer` agent in Phase 3, include relevant
checkpoint context in the review prompt:

- Pass `key_decisions` so the reviewer understands design choices
- Pass `warnings` so the reviewer checks flagged concerns
- Compare `files_planned` vs `files_modified` to verify completeness

## Local-Merge (OPT-IN, Legacy)

> **OPT-IN LEGACY MODE.** The default topology is PR-per-golem (Phases D/M/R in
> `orchestrate/SKILL.md`). Use local-merge ONLY for tightly-coupled work where
> golems push to no remote (offline / no-PR worktree workflow). The orchestrator
> merging golem branches into its own branch — and syncing back — is exactly
> what PR-per-golem replaces. The merge/sync sections below are bannered
> superseded; conflict classification + test-runner detection (above) remain
> live.

Use these only when explicitly requested (`/workflow:orchestrate merge`, `review`,
`sync`).

### Merge (legacy Phase 2)

1. **Resolve agent identifier**: numeric → map from the status table; branch
   name → use directly; `all` → iterate agents with pending commits.
1. **Preview**: `MERGE_BASE=$(git merge-base HEAD <agent-branch>)`;
   `git log --oneline "$MERGE_BASE"..<agent-branch>`; diffstat. Confirm.
1. **Merge**: `git merge --no-ff <agent-branch> -m "merge(<agent-branch>): …"`
   (or `--squash` on request).
1. **Conflicts**: dispatch `rebase-agent` for trivial; escalate non-trivial
   (see § Conflict Classification above).
1. **Run tests** (see § Test Runner Detection above); warn on
   failure, do not auto-revert.
1. **Report** the merge commit. Suggest `/clear` if context is large.

### Review (legacy Phase 3)

Per-PR review is normally the **golem's** job (the `/workflow:ship-issue` review
loop). This phase applies only after a local merge.

1. `MERGE_COMMIT=$(git log -1 --merges --format='%H')`.
1. **Run the `code-review` harness** via the Workflow tool on the `path=` from
   `${CLAUDE_PLUGIN_ROOT}/scripts/harness-stage.sh stage code-reviewer` (#973),
   passing
   `args: { diff: "<git diff \"${MERGE_COMMIT}^1\" \"${MERGE_COMMIT}\">", files: [<changed>] }`.
   It returns the `finding-schema.md` object. **Bound this invocation in
   wall-time (#224)** — it fans out reviewer subagents; invoke it as a
   background task with the caller-side timeout (a timed-out review is
   **partial**). See `mode-protocol.md` § *Bounding a Workflow invocation in
   wall-time*.
1. **Apply corrections** in a single commit trailered `Reviewed-by: orchestrate`.
1. **Run tests**; report a summary table.

### Sync (legacy Phase 4)

1. `ORCH_BRANCH=$(git branch --show-current)`.
1. For each `git branch --list 'agent*' | /usr/bin/sort`:
   `git checkout <branch>; git merge "$ORCH_BRANCH" -m "sync: …"`; on conflict
   `git merge --abort` and skip.
1. Return to `$ORCH_BRANCH`; remove `status/in-progress` /
   `status/commit-pending` labels for synced issues. Report a sync table.
