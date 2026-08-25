# Next Issue — State & Reference

Reference companion for `SKILL.md`. Load this at the start of every
`/workflow:next-issue` invocation for the state file schema, priority query commands,
and branch naming rules.

---

## State File

Path: `.claude/memory/tmp/next-issue-{N}.json`

Where `{N}` is the issue number (e.g., `next-issue-101.json` for issue #101).

### JSON Schema

State files are JSON validated against
`schemas/next-issue-state.schema.json` (co-located in this skill directory).
Write using the Write tool:

```json
{
  "version": 2,
  "issue": 101,
  "title": "Fix critical auth bypass in session handler",
  "phase": "implement",
  "branch": "fix/issue-101-auth-bypass",
  "plan": "Validate session token expiry before granting access",
  "started": "2026-02-27",
  "platform": "github",
  "autonomy_level": 3,
  "contexts": ["security", "auth"],
  "active_loops": ["make-it-work", "make-it-secure", "make-it-tested"],
  "checkpoint": {
    "completed_phase": "plan",
    "key_decisions": [
      "Using environment variable for timeout, not config file",
      "Session.ts needs backward compat with existing JWT tokens"
    ],
    "files_modified": [],
    "files_planned": [
      "src/config/timeouts.ts",
      "src/auth/session.ts",
      "tests/auth/session.test.ts"
    ],
    "warnings": [
      "Tests currently mock the timeout value — must update mocks"
    ],
    "next_action": "Begin implementation loop: make-it-work"
  }
}
```

### Fields

| Field          | Required | Description                                          |
| -------------- | -------- | ---------------------------------------------------- |
| `version`      | yes      | Always `2` (JSON format)                             |
| `issue`        | yes      | Issue number (integer)                               |
| `title`        | yes      | Issue title (string)                                 |
| `phase`        | yes      | Current phase: `select`, `plan`, `implement`, `ship` |
| `branch`       | no       | Branch name (set after select)                       |
| `plan`         | no       | One-line plan summary (set after plan)               |
| `started`      | yes      | ISO date when work began                             |
| `platform`     | yes      | `github` or `gitlab`                                 |
| `autonomy_level` | no     | Autonomy level 1–4 per `orchestrate/autonomy-levels.md` (#174) — the sole autonomy field. Set via `--level N`; absent → L1. `severity/critical` caps at L3 |
| `plan_comment_url` | no   | URL of posted plan comment (L4 plan-auto-passed path only) |
| `contexts`     | no       | Domain contexts for this issue                       |
| `active_loops` | no       | Implementation loops to execute                      |
| `checkpoint`   | no       | Phase transition checkpoint (see below)              |

The `autonomy_level` value is **computed by**
`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level …` (#190), not
hand-derived — the description above tabulates what that resolver emits. (The
resolver also emits runtime-only `plan_gated`/`perm_mode` dispositions; those are
consumed in-session, not persisted. The `autonomous`/`plan_gated` state-file
mirror fields were dropped in #215.)

### State Lifecycle

**Write state** — use Write tool with the JSON above.

**Clear state** — after successful ship, delete the per-issue state file
(`.claude/memory/tmp/next-issue-{N}.json`).

**Discovery** — to find all active state files:

```bash
ls .claude/memory/tmp/next-issue-*.json 2>/dev/null
```

If no `.json` files found, check for legacy `.md` files:

```bash
ls .claude/memory/tmp/next-issue-*.md 2>/dev/null
```

This returns all in-progress issue state files. Used by Phase 0 for resume
disambiguation when multiple agents are working in parallel.

**Stale state detection** — before offering to resume, validate:

1. Check if the issue is still open:
   - GitHub: `gh issue view {N} --json state --jq .state`
   - GitLab: `glab issue view {N}`
1. Check if the branch exists: `git branch --list {branch}`
1. If issue is closed or branch is gone → silently delete the state file and
   proceed to Phase 1 (don't ask the user about stale work)

---

## Checkpoint

The `checkpoint` object captures context that survives a `/clear` reset. It is
written to the state file before each reset point so the next phase can pick
up with full context.

### What to Capture

| Field             | Content                                                     |
| ----------------- | ----------------------------------------------------------- |
| `completed_phase` | Phase that just finished                                    |
| `key_decisions`   | Non-obvious choices that affect downstream work             |
| `files_modified`  | What changed so far (avoids re-scanning)                    |
| `files_planned`   | What still needs to change                                  |
| `scope_expansions` | Decomposition the plan lens added to scope, or a recorded decline (#756) — see `plan-sizing.md`. Marks the growth PLANNED so `drift-detect` does not read it as scope creep |
| `warnings`        | Discoveries the next phase should know about                |
| `next_action`     | Explicit directive for post-reset pickup                    |
| `loop_state`      | Implementation loop progress (completed/remaining/criteria) |

### Good vs Bad key_decisions

**Good** (non-obvious, affects downstream):

- "Using environment variable for timeout, not config file"
- "Session.ts needs backward compat with existing JWT tokens"
- "Chose merge commit over squash — agent made 3 distinct logical changes"

**Bad** (derivable from code or too vague):

- "Modified session.ts" (that's what `files_modified` is for)
- "Fixed the bug" (no useful context)
- "Used TypeScript" (obvious from the codebase)

### When to Write Checkpoints

Write or update the checkpoint before every reset point (see Reset Points
below). Each checkpoint overwrites the previous one — only the most recent
phase transition matters.

---

## Reset Points

Reset points are natural boundaries where the conversation context can be
safely cleared. The state file (with checkpoint) preserves continuity.

| Pipeline Phase      | Reset Mode | Why                                                              |
| ------------------- | ---------- | ---------------------------------------------------------------- |
| After plan approval | Suggest\*  | Exploration context is stale; implementation needs only the plan |
| Between impl. loops | Automatic  | Each loop runs as separate Task invocation (natural boundary)    |
| After review        | Suggest    | Implementation context is stale; shipping needs only the result  |
| After ship          | Required   | Everything is stale; clean slate for next issue                  |
| Context at threshold | Suggest\*\* | Accumulated context now costs ~3x the floor for identical work (#784) |

\*\* **Size-triggered reset (#784).** The rows above are keyed to *phase*; this
one is keyed to *size*, and it can fire at any of them. Run
`scripts/context-budget.sh check <worktree>` at a reset point in a golem or other
long unattended run; on a `handoff` verdict write the checkpoint and end the
session so the resumed one starts at the floor rather than at 400k. It reuses the
`checkpoint` object below unchanged — **no new state format**. An **interactive**
session gets a one-line advisory and is never cycled. Full protocol:
`handoff-protocol.md`.

\* **`--ship` fast-path exception**: when `/workflow:next-issue` is invoked with `--ship`
(or `--now`) on an `effort/trivial`/`small` issue, the "After plan approval"
reset is **skipped** — the run chains straight into `/workflow:ship-issue` in the
same context (the small planning footprint does not justify a reset). The
plan-approval gate itself is preserved, and the run never selects L4. For
`effort/medium`/`large` the reset point is unaffected.

\* **L3–L4 exception**: when `/workflow:next-issue` runs at **L3 or L4** (`--level 3`/`4`)
— **every** reset point above is bypassed: the run invokes `/workflow:ship-issue` in the
same turn (via the `Skill` tool) and never reaches the "After plan approval",
"After review", or "After ship" boundaries as distinct resets. The orchestrate
golem launch's `;`-chained `/workflow:ship-issue` is the only resume path if
the turn exits early. Such a run sets `autonomy_level`. Whether it removes the
**plan-approval gate** is level-driven (see `SKILL.md` § Autonomy Levels): an
**L4** run
(non-critical) auto-passes the plan gate; an **L1–L3** run — including a capped
`severity/critical` — keeps it and pauses at `ExitPlanMode` for human approval
before continuing. (An **L1–L2** run stops at the routine ship gates too, so it
does not reach this in-turn ship handoff.)

\* **Linked-worktree adaptation**: the reset points above are **Suggest** mode
(not skipped) inside a linked worktree — e.g. a `/workflow:golem` run — but the suggestion
is **worktree-aware**. This matters for **any plan-gate-kept L1–L2 run** that
reaches the "After plan approval" reset inside a worktree — most commonly
`effort/medium`/`large` issues (never `--ship`-eligible), but also an
`effort/trivial`/`small` issue run without `--ship`/`--now` (the `--ship`
fast-path is the only thing that skips this reset, and it is opt-in). A bare
`/clear` may return the session
to the **main checkout** and drop the worktree cwd, so the resume instruction
carries an `EnterWorktree` re-entry step before `/workflow:next-issue` (see the Reset
Suggestion Template below). Detect the worktree with the repo-standard idiom
(`git rev-parse --git-dir` != `git rev-parse --git-common-dir`; the same check the
golem nesting guard and `ship-issue/execute-protocol.md` use). The L3–L4 exception
above already bypasses these resets entirely, so the adaptation only applies to a
plan-gate-kept L1–L2 run.

| Orchestrator Action | Reset Mode | Why                                                        |
| ------------------- | ---------- | ---------------------------------------------------------- |
| After each merge    | Suggest    | Agent diff context is stale; next merge is different files |
| After sync          | Suggest    | Mechanical rebase output is noise                          |

### Reset Modes

| Mode          | Behavior                                                              |
| ------------- | --------------------------------------------------------------------- |
| **Suggest**   | Suggest `/clear` with reason; continue if user declines               |
| **Automatic** | Sub-agent/Task boundary = natural context boundary (no action needed) |
| **Required**  | Write checkpoint, stop, require `/clear` + `/workflow:next-issue` to resume    |

### Reset Suggestion Template

When suggesting a reset from the **primary checkout**, use this format:

> Exploration/planning phase complete. Context can be safely cleared — state
> saved to `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then
> `/workflow:next-issue` to resume from {next_phase}.

When suggesting a reset from a **linked worktree** (`git rev-parse --git-dir` !=
`git rev-parse --git-common-dir`), a bare `/clear` may drop the worktree cwd, so
use the worktree-aware variant:

> Exploration/planning phase complete. Context can be safely cleared — state
> saved to `.claude/memory/tmp/next-issue-{N}.json`. `/clear` may return you to
> the main checkout, so after it re-enter this worktree with
> `EnterWorktree({ path: ".worktrees/issue-{N}" })`, then run `/workflow:next-issue` to
> resume from {next_phase}.

If the user declines, continue normally — the suggestion is advisory.

---

## Status Labels

Five labels track in-flight or not-ready work and prevent an issue from being
picked up:

| Label                   | Set by                        | Meaning                                               |
| ----------------------- | ----------------------------- | ----------------------------------------------------- |
| `status/in-progress`    | `/workflow:next-issue` (Phase 1)       | An agent has selected this issue and is working on it |
| `status/pr-pending`     | `/workflow:ship-issue` (Option 1) | A PR has been created; awaiting review/merge          |
| `status/commit-pending` | `/workflow:ship-issue` (Option 3) | Fix committed locally but not yet pushed              |
| `status/on-hold`        | Manual                        | Issue intentionally deferred; not ready to work on    |
| `status/blocked`        | Manual                        | Issue has an unresolved dependency; not ready to work |

The first four labels are **excluded** by the `--search` filter in every
priority query (see below) so that in-progress issues are never re-selected.
`status/blocked` is handled by the **blocked-by exclusion** (see below): it is
filtered the same way, alongside parsed `Blocked by` / `Depends on` / native
blocked-by references.

---

## Blocked-by Exclusion

Selection must never dispatch an issue whose declared dependencies are still
open — a golem would plan against an unresolved blocker and, on an **L4**
(gate-skipping) path, could resolve the upstream decision by fiat. This
exclusion is a **sibling of the status-label exclusion above**, applied at the
same point in the priority loop, so `orchestrate` dispatch and pool refill
inherit it automatically.

In brief: a candidate is **blocked** when a `status/blocked` label, a
`Blocked by #N` / `Depends on #N` body reference, or a GitHub native `blockedBy`
relationship points at an **open** issue. **Priority** selection **skips** a
blocked candidate (`#572 skipped — blocked by open #467`) and walks on;
**explicit** selection (`/workflow:next-issue 572`) instead **queues the open
dependencies first** and works them toward the named target (§ Dependency
Queue). `--force-target` / `--no-deps` restores warn-and-proceed.

> **On-demand companion:** the full detection recipe (native + body + label,
> per-platform), the exact skip vs. queue dispositions, and the `--force-target`
> escape hatch live in **`dependency-queue.md`** — load it only when selection
> actually touches a blocked issue.

---

## Dependency Queue

When an operator explicitly names an issue that has **open** declared
dependencies (`/workflow:next-issue 5` where #5 declares `Depends on #2, #4`),
`/workflow:next-issue` resolves the dependencies and works them first, driving toward the
named **target** across successive runs. The queue lives in a **singleton** file
separate from the per-issue state (it survives each dependency landing, which
`/workflow:ship-issue` deleting a per-issue state file would not):

Path: `.claude/memory/tmp/next-issue-queue.json` (schema:
`schemas/next-issue-queue.schema.json`).

In brief: resolve the target's open blockers transitively (cycle-safe,
diamond-safe), order them topologically deepest-first with the target last,
persist the queue, and work the **first open, unblocked** entry each cycle. A
plain `/workflow:next-issue` advances the queue (dropping closed entries, recomputing
`active`, deleting the file once only the target remains); a detected cycle stops
with an `ERROR:` and points at `--force-target`.

> **On-demand companion:** the full resolution algorithm (transitive walk, cycle
> detection, topological order), the queue schema fields, the advancing/resuming
> rules, and the orchestrate golem-cache-coherence caveat live in
> **`dependency-queue.md`** — load it only when building or advancing a queue.

---

## Priority Ordering

Query issues in this order — first match wins. This is a nested loop:
severity (descending) x effort (ascending), so critical+trivial issues are
picked first and low+large issues last.

### GitHub (`gh`)

```bash
# Loop through severity levels (most critical first)
for severity in critical high medium low; do
  # Within each severity, prefer smaller effort
  for effort in trivial small medium large; do
    gh issue list \
      --label "severity/${severity}" \
      --label "effort/${effort}" \
      --state open \
      --assignee "" \
      --search "-label:status/in-progress -label:status/pr-pending -label:status/commit-pending -label:status/on-hold -label:status/blocked" \
      --limit 1 \
      --json number,title,labels,body
  done
done
```

After the query returns a candidate, apply the **blocked-by exclusion** above
(parse `Blocked by`/`Depends on`/native `blockedBy`, check each referenced
issue's state): if any blocker is still open, skip the candidate with a
one-line note and continue the priority walk. The `-label:status/blocked` filter
covers the operator-set label cheaply; the per-candidate parse covers
body/native references the query can't express.

### GitLab (`glab`)

GitLab's `glab issue list` does not support negative label filters natively.
Fetch slightly more results and post-filter:

```bash
for severity in critical high medium low; do
  for effort in trivial small medium large; do
    # Fetch up to 5 and filter out status labels
    glab issue list \
      --label "severity/${severity}" \
      --label "effort/${effort}" \
      --not-assignee \
      --per-page 5 \
    | while read -r line; do
        # Skip issues with status/in-progress, status/pr-pending, status/commit-pending, status/on-hold, or status/blocked labels
        issue_num=$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk '{print $1}')
        labels=$(glab issue view "$issue_num" --output json | /usr/bin/grep -o '"status/[^"]*"')
        if ! /usr/bin/printf '%s\n' "$labels" | /usr/bin/grep -qE 'status/in-progress|status/pr-pending|status/commit-pending|status/on-hold|status/blocked'; then
          /usr/bin/printf '%s\n' "$line"
          break
        fi
      done
  done
done
```

### Collision-aware selection (pool refill)

The priority loop above picks the single highest-priority eligible issue. The
**blocked-by exclusion** (above) is already part of that loop, so a candidate
with an open blocker is skipped before any collision logic runs — pool refill
inherits dependency-awareness for free. When the **orchestrate worker pool**
(Phase P) refills a free slot, it then layers an **in-flight collision check**
on top of that order: a freshly-picked issue whose work is predicted to overlap
an in-flight golem's files would collide on the merge train (#602), so the pool
prefers the next priority issue that is predicted **disjoint**.

The overlap prediction is heuristic — the candidate issue's `## Affected Files`
section plus its `component/*` labels vs each in-flight golem's changed files
(`gh pr view <N> --json files`, or the golem's issue `## Affected Files` before
it has a PR). The rule:

- Walk the priority order; pick the first candidate predicted disjoint from
  **every** in-flight golem **and** from any candidate already picked this sweep.
- A candidate with **no** predicted files is dispatchable but ranked last (don't
  starve the pool on pure uncertainty) — a slot is held only on a **predicted**
  collision, never on mere unknown.
- If only colliding candidates remain, **hold** the slot (leave it idle) rather
  than dispatch a guaranteed-colliding pick.

The actual consumer is `orchestrate/workflow.js` `mode: "pool"` (pure
computation); this section documents the shared heuristic where the priority
logic lives. A plain `/workflow:next-issue` run (no pool) ignores the collision check —
it selects strictly by priority.

### Fallback

If no labeled issues match, fall back to the oldest open issue (still
excluding status labels):

```bash
# GitHub
gh issue list \
  --state open \
  --search "-label:status/in-progress -label:status/pr-pending -label:status/commit-pending -label:status/on-hold -label:status/blocked" \
  --limit 1 \
  --json number,title,labels,body

# GitLab — fetch more and post-filter as above
glab issue list --per-page 5
```

---

## Branch Naming Convention

Format: `{prefix}/issue-{N}-{slug}`

### Prefix Derivation

Derive from issue labels. First match wins:

| Label pattern       | Prefix      | Example                         |
| ------------------- | ----------- | ------------------------------- |
| `type/bug` or `fix` | `fix/`      | `fix/issue-101-auth-bypass`     |
| `type/feature`      | `feature/`  | `feature/issue-42-user-search`  |
| `type/docs`         | `docs/`     | `docs/issue-55-api-reference`   |
| `type/test`         | `test/`     | `test/issue-60-add-unit-tests`  |
| `type/refactor`     | `refactor/` | `refactor/issue-70-split-utils` |
| (no type label)     | `chore/`    | `chore/issue-99-update-deps`    |

### Slug Derivation

From the issue title:

1. Lowercase the title
1. Replace non-alphanumeric characters with hyphens
1. Collapse consecutive hyphens
1. Trim to 40 characters max
1. Remove trailing hyphens

Example: `"Fix Critical Auth Bypass in Session Handler"` → `fix-critical-auth-bypass-in-session-handler` → trimmed to `fix-critical-auth-bypass-in-session`

### Branch Creation

Always branch from the latest remote main:

```bash
git fetch origin main
git checkout -b {prefix}/issue-{N}-{slug} origin/main
```

---

## Integration Notes

### git-workflow

Follow commit conventions from the `git-workflow` skill:

- Conventional commit prefix: `feat:`, `fix:`, `chore:`, `docs:`, `test:`,
  `refactor:`
- Include `Closes #{N}` in the commit body
- Keep subject under 72 characters, imperative mood

### development-workflow

For `effort/medium` and `effort/large` issues, load
`development-workflow/phase-details.md` and follow its phased approach:

- Phase 1 (Make it Work) — get the core change working
- Phase 2 (Make it Right) — clean up, add proper error handling
- Phase 3 (Make it Tested) — add/update tests

For `effort/trivial` and `effort/small` issues, a brief inline plan suffices.

### codebase-audit

The priority labels (`severity/*`, `effort/*`) are created by the
`/review-audit:codebase-audit` command's issue-writer agents. This skill is designed to
consume those labels directly — no label mapping needed.

### Commit Message for Issue Closure

**CRITICAL**: Every commit MUST include `Closes #{N}` in the body. Without
this, the issue will not auto-close when the PR is merged.

```text
{type}({scope}): {description}

{optional body explaining the change}

Closes #{N}
```

Where `{type}` matches the branch prefix (`fix` → `fix:`, `feature` → `feat:`,
`refactor` → `refactor:`, etc.).

**Verification**: After committing, run `git log -1 --format=%B` to confirm
the `Closes #{N}` line is present. If missing, amend to add it.
