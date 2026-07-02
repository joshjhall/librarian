# Next Issue — State & Reference

Reference companion for `SKILL.md`. Load this at the start of every
`/next-issue` invocation for the state file schema, priority query commands,
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
  "autonomous": true,
  "plan_gated": true,
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
| `autonomous`   | no       | True when started autonomously (`--autonomous`/`--auto`/env) |
| `plan_gated`   | no       | True when an autonomous run keeps the plan checkpoint (medium+/critical/no-effort or `--plan-gate`); false skips plan |
| `plan_comment_url` | no   | URL of posted plan comment (fully-autonomous only)   |
| `contexts`     | no       | Domain contexts for this issue                       |
| `active_loops` | no       | Implementation loops to execute                      |
| `checkpoint`   | no       | Phase transition checkpoint (see below)              |

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

## Backward Compatibility

### Stage 1: Legacy Singleton Migration (existing)

If `.claude/memory/tmp/next-issue-state.md` exists, read its `issue:` field,
rename to `.claude/memory/tmp/next-issue-{N}.md`, then proceed to Stage 2.

### Stage 2: YAML Frontmatter → JSON Migration (new)

If `.claude/memory/tmp/next-issue-{N}.md` files exist (YAML frontmatter
format), migrate each to `.json`:

1. Read the `.md` file and extract YAML frontmatter fields
1. Write a new `.json` file with the same fields plus `"version": 2`
1. Delete the `.md` file

**Edge case**: If both `.md` and `.json` exist for the same issue number,
prefer the `.json` file and delete the `.md` duplicate.

The migration is automatic and happens once during Phase 0 discovery.

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

\* **`--ship` fast-path exception**: when `/next-issue` is invoked with `--ship`
(or `--now`) on an `effort/trivial`/`small` issue, the "After plan approval"
reset is **skipped** — the run chains straight into `/ship-issue` in the
same context (the small planning footprint does not justify a reset). The
plan-approval gate itself is preserved, and `autonomous` stays false. For
`effort/medium`/`large` the reset point is unaffected.

\* **`--autonomous` exception**: when `/next-issue` is invoked with
`--autonomous` (deprecated alias `--auto`) or `NEXT_ISSUE_AUTONOMOUS=1`,
**every** reset point above is bypassed — the
autonomous run invokes `/ship-issue` in the same turn (via the `Skill`
tool) and never reaches the "After plan approval", "After review", or "After
ship" boundaries as distinct resets. The orchestrate golem launch's
`;`-chained `/ship-issue --autonomous` is the only resume path if the turn exits
early. Unlike `--ship`, `--autonomous` sets `autonomous: true`. Whether it removes the
**plan-approval gate** depends on `plan_gated` (see `SKILL.md` § Autonomous
Mode): a fully-autonomous run (`effort/trivial`/`small`, non-critical, no
`--plan-gate`) skips the gate; a plan-gated run (`effort/medium`/`large`,
`severity/critical`, no-effort-label, or `--plan-gate`) keeps it and pauses at
`ExitPlanMode` for human approval before continuing autonomously.

| Orchestrator Action | Reset Mode | Why                                                        |
| ------------------- | ---------- | ---------------------------------------------------------- |
| After each merge    | Suggest    | Agent diff context is stale; next merge is different files |
| After sync          | Suggest    | Mechanical rebase output is noise                          |

### Reset Modes

| Mode          | Behavior                                                              |
| ------------- | --------------------------------------------------------------------- |
| **Suggest**   | Suggest `/clear` with reason; continue if user declines               |
| **Automatic** | Sub-agent/Task boundary = natural context boundary (no action needed) |
| **Required**  | Write checkpoint, stop, require `/clear` + `/next-issue` to resume    |

### Reset Suggestion Template

When suggesting a reset, use this format:

> Exploration/planning phase complete. Context can be safely cleared — state
> saved to `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then
> `/next-issue` to resume from {next_phase}.

If the user declines, continue normally — the suggestion is advisory.

---

## Status Labels

Five labels track in-flight or not-ready work and prevent an issue from being
picked up:

| Label                   | Set by                        | Meaning                                               |
| ----------------------- | ----------------------------- | ----------------------------------------------------- |
| `status/in-progress`    | `/next-issue` (Phase 1)       | An agent has selected this issue and is working on it |
| `status/pr-pending`     | `/ship-issue` (Option 1) | A PR has been created; awaiting review/merge          |
| `status/commit-pending` | `/ship-issue` (Option 3) | Fix committed locally but not yet pushed              |
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
open — a golem would plan against an unresolved blocker and, on a
fully-autonomous path, could resolve the upstream decision by fiat. The
blocked-by exclusion is a **sibling of the status-label exclusion above**: it is
applied at the same point in the priority loop, so `orchestrate` dispatch and
pool refill (which reuse this ordering) inherit it automatically.

Priority and explicit selection handle a blocked issue **differently but
symmetrically in intent** — neither drops a golem into planning against an open
blocker. Priority selection **skips** a blocked candidate and walks on (it can
pick a different issue). Explicit selection can't just pick something else — the
operator named an issue — so instead of skipping it **queues the open
dependencies first** and works them in order toward the named target (see
`## Dependency Queue` below). The old warn-and-proceed behavior is preserved
only behind the `--force-target` / `--no-deps` override.

A candidate is **blocked** when ANY of these references an OPEN issue:

1. A `status/blocked` label on the candidate (the operator-set signal).
2. A `Blocked by #N` reference in the candidate body (case-insensitive,
   `blocked by #N` / `Blocked-by: #N`).
3. A `Depends on #N` reference in the candidate body (case-insensitive,
   `depends on #N` / `Depends-on: #N`).
4. A GitHub native **blocked-by** relationship (the `blockedBy` field).

### Determining blocker state

For a candidate issue `#C`, gather referenced blocker numbers and check each
one's state. On GitHub:

```bash
# 1. Native blocked-by relationships (newline-separated issue numbers, may be empty).
native_blockers=$(gh issue view "$C" --json blockedBy \
  --jq '.blockedBy[]?.number' 2>/dev/null)

# 2. Body references: Blocked by #N / Depends on #N (case-insensitive).
body=$(gh issue view "$C" --json body --jq '.body' 2>/dev/null)
body_blockers=$(printf '%s\n' "$body" \
  | command grep -oiE '(blocked[ -]by|depends[ -]on):?[[:space:]]*#[0-9]+' \
  | command grep -oE '[0-9]+')

# 3. status/blocked label is read from the candidate's labels (already fetched
#    in the priority query's --json labels).

# Any referenced blocker still OPEN ⇒ candidate is blocked.
open_blockers=""
for b in $native_blockers $body_blockers; do
  state=$(gh issue view "$b" --json state --jq '.state' 2>/dev/null)
  if [ "$state" = "OPEN" ]; then
    open_blockers="$open_blockers #$b"   # collect for the skip note
  fi
done
```

On GitLab there is no native blocked-by JSON field exposed uniformly; rely on
the body references (`Blocked by #N` / `Depends on #N`) and the
`status/blocked` label, checking each referenced issue with
`glab issue view {N}` for its state.

### Applying the exclusion

- **Priority / pool-refill selection** (no explicit issue number): when a
  candidate is blocked, **skip it** and continue the priority walk to the next
  candidate — exactly as a `status/in-progress` hit is skipped. Emit a one-line
  note so the operator sees why it was passed over:

  > `#572 skipped — blocked by open #467, #563`

  List the open blocker numbers (and `status/blocked` if that label was the
  trigger). A candidate gated only by the `status/blocked` label notes
  `blocked by status/blocked label`.
- **Explicit single-issue selection** (`/next-issue 572`): the operator named
  the issue, so do **not** hard-block — but do **not** plan the named issue
  against its open blockers either. Naming an issue is a **target objective**,
  not an override of its dependency requirements. Instead **queue the open
  dependencies first** and work them toward the named target (the full algorithm
  is in `## Dependency Queue` below). In brief: resolve the named issue's open
  blockers transitively, build a topological work queue with the named target
  last, write `next-issue-queue.json`, and select the **first open, unblocked**
  entry (a dependency, usually) to plan **this** run instead of the target. A
  subsequent `/next-issue` advances the queue toward the target.

  The `--force-target` flag (alias `--no-deps`) restores today's
  warn-and-proceed for "I really do mean #572 now":

  > `WARNING: #572 is blocked by open #467, #563 — proceeding because you named
  > it explicitly with --force-target; the plan gate is your backstop.`

  With `--force-target`, proceed directly to Phase 2 for the named issue; the
  plan gate (see `SKILL.md` § Autonomous Mode) remains the human checkpoint for
  a plan-gated run. A detected dependency **cycle** also stops queuing and falls
  back to the same escape hatch (see `## Dependency Queue`), so an
  explicitly-named issue is never hard-blocked.
- **`status/blocked` label** is also added to the `--search` exclusion list in
  every priority query below, so a candidate carrying that label is filtered
  out by the query itself before per-candidate parsing even runs (cheaper, and
  covers the operator-set case without an extra API round-trip).

---

## Dependency Queue

When an operator explicitly names an issue that has **open** declared
dependencies (`/next-issue 5` where #5 declares `Depends on #2, #4`),
`/next-issue` resolves the dependencies and works them first, driving toward the
named **target** across successive runs. The queue lives in a **singleton** file
separate from the per-issue state:

Path: `.claude/memory/tmp/next-issue-queue.json` (schema:
`schemas/next-issue-queue.schema.json`).

It is deliberately **not** a field inside a `next-issue-{N}.json` state file:
`/ship-issue` deletes the per-issue state file when a dependency ships, which
would take a queue stored there with it. The separate file survives each
dependency landing, and every worked dependency still gets its own normal
`next-issue-{dep}.json` while in flight.

### Schema

```json
{
  "version": 1,
  "target": 5,
  "ordered": [4, 2, 5],
  "remaining": [4, 2, 5],
  "active": 4,
  "created": "2026-07-02",
  "platform": "github"
}
```

| Field       | Description                                                          |
| ----------- | ------------------------------------------------------------------- |
| `version`   | Always `1`                                                          |
| `target`    | The explicitly-named issue the queue drives toward (last in order)  |
| `ordered`   | Full topological order, deepest blocker first, target last (fixed)  |
| `remaining` | Not-yet-completed entries; shrinks as dependencies close            |
| `active`    | The entry selected to work this cycle (first open, unblocked)       |
| `created`   | ISO date the queue was created                                      |
| `platform`  | `github` or `gitlab`                                                |

### Resolution algorithm

For the named target `#T`, before selecting anything:

1. **Gather open blockers.** Reuse the blocker detection above verbatim
   (`status/blocked` label, `Blocked by #N` / `Depends on #N` body refs, native
   `blockedBy`), keeping only blockers whose state is **OPEN**.
1. **Resolve transitively.** A blocker may have its own open blockers. Walk the
   dependency graph from `#T`, expanding each issue's open blockers. Keep a
   graph-wide `resolved` set of issues already expanded so a shared blocker is
   expanded **once** — a diamond (e.g. `#5` depends on `#2` and `#3`, both of
   which depend on `#1`) is legal and re-reaching `#1` from a second parent is
   **not** a cycle.
1. **Be cycle-safe.** Cycle detection is separate from the `resolved` set above:
   track the **current ancestor path** (the chain of issues from `#T` down to
   the node being expanded, a DFS stack / parent-pointer chain). A cycle is a
   back-edge — a blocker that is already **on the current ancestor path**, not
   merely one already in `resolved`. Re-reaching a shared blocker via a
   different parent (the diamond case) is fine; re-reaching an **ancestor** is
   the cycle. On a back-edge, stop and surface a clear error — never loop:

   > `ERROR: dependency cycle detected (#5 → #2 → #5) — cannot queue; resolve
   > the cycle manually or pass --force-target to plan #5 directly.`

   Then stop (do not select). `--force-target` is the escape hatch.
1. **Handle missing / already-closed blockers gracefully.** A referenced issue
   that is already **closed** is not a blocker — drop it silently. A referenced
   issue that cannot be found (deleted, wrong number) is dropped with a one-line
   note (`note: referenced blocker #99 not found — ignoring`). Neither crashes
   the walk.
1. **Order topologically, deepest blocker first.** An issue with no open
   blockers of its own comes before one that depends on it. Among independent
   blockers at the same depth, tie-break by the existing severity × effort
   priority (see `## Priority Ordering`). The target `#T` is always last.
1. **Build and persist the queue.** `ordered = [dep_deepest, …, #T]`;
   `remaining = ordered`; `active` = the first open, unblocked entry. Write
   `next-issue-queue.json`.
1. **Select `active`, not `#T`.** Continue Phase 1 (assign, `status/in-progress`
   label, write `next-issue-{active}.json`) for the `active` issue. The named
   target is planned only once it is all that remains and is unblocked.

If `#T` has **no** open blockers, no queue is created — proceed normally to plan
`#T` (the explicit path is unchanged for an unblocked named issue).

### Advancing / resuming the queue

A plain `/next-issue` (no issue number) checks for `next-issue-queue.json` in
Phase 0 **before** priority selection:

- **Target-closed self-heal (check first).** If `target` (`#T`) is itself now
  **closed** — it was force-shipped directly under `--force-target`, closed
  manually, or de-duped while a queue for it still existed — the queue is stale
  and pointless. **Delete the queue file immediately** and fall through to
  ordinary priority selection, regardless of what `remaining` still holds. This
  is symmetric to the `active`-closed check below and prevents a stranded queue
  from looping forever once its target is gone.
- If the `active` issue is now **closed** (its dependency shipped), drop it from
  `remaining`.
- Recompute `active` = the first entry in `remaining` that is open **and**
  unblocked (its own open blockers, if any, resolve first — they are already in
  `ordered`), and target that issue for this run.
- When `remaining` reduces to just `#T` and `#T` is unblocked, target `#T`,
  **delete** the queue file (its own `next-issue-{T}.json` state takes over),
  and proceed to plan the target.
- If every `remaining` entry is still blocked (nothing actionable), surface a
  one-line status (`queue toward #5 blocked — #4 still open`) and stop.

An explicit `/next-issue {other}` while a queue exists starts fresh for
`{other}` and leaves the queue file untouched — the queue is target-keyed, not a
global priority override. (If `{other}` itself has open blockers, it builds its
own queue, replacing the file.)

### Autonomous interaction

An autonomous explicit run (`/next-issue 5 --autonomous`, as `orchestrate`
always dispatches) **queues and works the first unblocked dependency** this
turn — planning it, implementing it, and shipping its own PR — then leaves the
queue file for the next cycle. It does **not** auto-advance the whole chain
within one turn: each dependency is one golem / one PR (the natural PR-per-golem
granularity). Because `orchestrate`'s priority walk already **skips** blocked
issues, once a dependency PR merges the next dependency becomes unblocked and is
re-selected by ordinary priority selection — the queue file is primarily a
resume aid for a plain interactive `/next-issue` walking toward the target.
`--force-target` on an autonomous run restores warn-and-proceed and plans the
named target directly.

#### Orchestrate dispatch — golem-cache coherence

`orchestrate` dispatch (`/orchestrate dispatch 5`) labels `#5`
`status/in-progress`, writes a golem-status cache row keyed `issue: 5`
(`orchestrate/schemas/golem-status.schema.json`), and launches
`/next-issue 5 --autonomous` inside `golem-5`'s worktree. If `#5` has open
blockers, the default queuing behavior redirects that golem to a **dependency**
(say `#2`) — it commits `next-issue-2.json` and a PR for `#2`, while the golem
process is still cached as `golem-5 / issue: 5`. That is a cache-vs-reality
desync: monitor sweeps, `golem-status.sh`, and pool collision prediction
(`gh pr view <N> --json files`) all key off the cached issue.

Two safe ways to dispatch a blocked issue under orchestrate, until the
golem-status cache learns about queue redirects:

- **Preferred — let priority selection resolve order.** Pool/priority refill
  already **skips** blocked issues, so it never dispatches `#5` while `#2`/`#4`
  are open; it dispatches the unblocked dependencies first, and `#5` becomes
  eligible only once they close. No explicit-dispatch redirect happens, so no
  desync.
- **Force-dispatch — pass `--force-target`.** An operator who deliberately
  force-dispatches a specific blocked issue should pass
  `/next-issue 5 --force-target --autonomous` so the golem works exactly the
  cached issue (`#5`), keeping `golem-5` coherent (the plan gate is the
  backstop).

Teaching the golem-status cache to record a queue redirect (e.g. a
`queued_target` field, or writing the `active` issue into the cache `issue`
field) is **out of scope for this change** and tracked as an orchestrate
follow-up. A plain (non-orchestrate) explicit `/next-issue 5` is unaffected —
it has no golem cache to desync.

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
logic lives. A plain `/next-issue` run (no pool) ignores the collision check —
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
`/codebase-audit` command's issue-writer agents. This skill is designed to
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
