# Next Issue — Blocked-by Exclusion & Dependency Queue

On-demand companion for `next-issue/SKILL.md` and `state-format.md`. Load this
**only** when selection touches a blocked issue — i.e. an operator explicitly
names an issue that has open declared dependencies, or a priority candidate
carries a `Blocked by` / `Depends on` / `status/blocked` reference. The common
path (an unblocked issue) never needs it, which is why it lives outside the
always-loaded `state-format.md`.

`state-format.md` keeps brief `## Blocked-by Exclusion` and `## Dependency Queue`
pointer stubs; the full algorithm is here.

---

## Blocked-by Exclusion

Selection must never dispatch an issue whose declared dependencies are still
open — a golem would plan against an unresolved blocker and, on an **L4**
(gate-skipping) path, could resolve the upstream decision by fiat. The
blocked-by exclusion is a **sibling of the status-label exclusion** (see
`state-format.md` § Status Labels): it is applied at the same point in the
priority loop, so `orchestrate` dispatch and pool refill (which reuse this
ordering) inherit it automatically.

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
  plan gate (see `SKILL.md` § Autonomy Levels) remains the human checkpoint for
  a plan-gated run. A detected dependency **cycle** also stops queuing and falls
  back to the same escape hatch (see `## Dependency Queue`), so an
  explicitly-named issue is never hard-blocked.
- **`status/blocked` label** is also added to the `--search` exclusion list in
  every priority query (see `state-format.md` § Priority Ordering), so a
  candidate carrying that label is filtered out by the query itself before
  per-candidate parsing even runs (cheaper, and covers the operator-set case
  without an extra API round-trip).

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
   priority (see `state-format.md` § Priority Ordering). The target `#T` is
   always last.
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

### Gate-skipping (L3–L4) interaction

A gate-skipping explicit run (`/next-issue 5 --level 4`, as `orchestrate` always
dispatches) **queues and works the first unblocked dependency** this turn —
planning it, implementing it, and shipping its own PR — then leaves the queue
file for the next cycle. It does **not** auto-advance the whole chain within one
turn: each dependency is one golem / one PR (the natural PR-per-golem
granularity). Because `orchestrate`'s priority walk already **skips** blocked
issues, once a dependency PR merges the next dependency becomes unblocked and is
re-selected by ordinary priority selection — the queue file is primarily a
resume aid for a plain interactive `/next-issue` walking toward the target.
`--force-target` on such a run restores warn-and-proceed and plans the named
target directly.

#### Orchestrate dispatch — golem-cache coherence

`orchestrate` dispatch labels a blocked target `status/in-progress` and caches a
golem-status row keyed to it, but the default queuing redirects that golem to a
**dependency** (its own state file + PR), leaving the cache keyed to the target
— a cache-vs-reality desync that monitor sweeps, `golem-status.sh`, and pool
collision prediction all read. Two safe dispatches until the cache learns about
redirects:

- **Preferred — let priority selection resolve order.** Pool/priority refill
  already skips blocked issues, so it dispatches the unblocked dependencies
  first and the target only once they close — no explicit-dispatch redirect, no
  desync.
- **Force-dispatch — pass `--force-target`.** An operator force-dispatching a
  specific blocked issue passes `/next-issue 5 --force-target --level 4` so the
  golem works exactly the cached issue (the plan gate is the backstop).

Teaching the golem-status cache to record a queue redirect is an orchestrate
follow-up, out of scope here. A plain (non-orchestrate) explicit `/next-issue 5`
has no golem cache to desync.
