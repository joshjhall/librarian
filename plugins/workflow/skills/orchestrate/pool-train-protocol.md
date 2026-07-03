# Orchestrate — Pool & Train Protocol

Companion to `orchestrate/SKILL.md`. Load before **Phase P** (worker pool) or
**Phase T** (integration train). Phase D dispatches a fixed set of golems once;
Phase P turns that set into a fixed-size self-refilling pool, and Phase T lands a
batch of their green PRs with one approval. The pool feeds work in; the train
lands it.

## Phase P — Worker Pool

Phase D dispatches a fixed **set** of golems once. Phase P turns that set into a
fixed-size **pool**: maintain up to **N** concurrent golems, and whenever a slot
frees (a golem's PR merges and its worktree is pruned), automatically pull the
next non-colliding issue from the backlog into a **fresh** worktree — until the
backlog is empty and all slots are idle. The key property is a **bounded
worktree footprint** (≤ N worktrees → bounded disk / container load) with
continuous throughput, plus a clean **drain** off-switch so the operator can
reset orchestrator context or restart services without losing in-flight work.

The pool pairs with Phase T: the **pool feeds work in**, the **train lands it**.

**Pool state** lives in `.worktrees/.status/pool.json` (schema:
`schemas/pool-status.schema.json`). It is **authoritative for operator policy**
— the pool `size` and the `accepting` state — and a display cache for everything
else (PR + issue-label state stay authoritative for golem liveness):

```json
{ "size": 3, "accepting": "accepting", "slots": [ … ], "backlog_depth": 7 }
```

`accepting` is a three-state policy: `accepting` (refill a free slot from the
backlog), `draining` (stop refills, let in-flight golems finish to idle — a
one-way wind-down), `paused` (freeze refills without draining; resumable).

### Refill loop

The pool advances **on each Phase M monitor sweep** (no background daemon — the
existing cadence is the clock):

1. **Free slots.** The Phase M sweep already detects merged PRs; for each merged
   golem, prune its worktree (`${CLAUDE_PLUGIN_ROOT}/scripts/worktree-rm.sh {N}`, which also deletes the
   branch). That frees a slot.

1. **Refill decision.** If `pool.accepting == "accepting"` **and** a slot is
   free **and** the backlog is non-empty, compute the refill plan. Gather:

   - **in-flight** golems with their changed files (`gh pr view <N> --json files`
     for golems with a PR; the issue's `## Affected Files` section otherwise),
   - the **backlog** — the next issues in `next-issue` priority order
     (`state-format.md` § Priority Ordering, status-label-excluded), each with
     its predicted files (issue `## Affected Files` + `component/*` labels).

   Invoke the Workflow tool on `~/.claude/skills/orchestrate/workflow.js` with:

   ```text
   args: {
     mode: "pool",
     pool:     { size: <N>, accepting: "<state>" },
     inflight: [{ issue, golem, branch, files: [<paths>] }, …],
     backlog:  [{ issue, files: [<predicted paths>] }, …],

     // OPTIONAL — lane-aware serial refill (when tracks are active). Omit both
     // for a plain flat pool (behavior unchanged).
     tracks:    [{ lane, queue: [{ issue, files: [<paths>] }, …] }, …],
     laneSlots: [<lane index per free lane slot this sweep>, …],
   }
   ```

   The harness is **pure computation** — it never dispatches, merges, or pushes.
   It returns `pool` = `{ free_slots, picks, held, held_slots, excess }`:

   - **`picks`** — the issues to dispatch into free slots, each predicted to
     collide with **neither** an in-flight golem **nor** an earlier pick (keeps
     #602's merge train conflict-light). **Lane-scoped when `tracks`/`laneSlots`
     are supplied** (each freed lane's next queued issue, then a global-priority
     fill for untagged / exhausted-lane slots); flat priority order otherwise.
   - **`held`** — candidates skipped this sweep on a predicted file overlap
     (with the colliding reason). A slot is held (left idle) rather than filled
     with a guaranteed-colliding pick when only colliding candidates remain.
   - **`excess`** — golems beyond `size` after a `pool <N>` shrink. **Report
     them to drain — never kill a golem.**

1. **Dispatch each pick** exactly as Phase D: `${CLAUDE_PLUGIN_ROOT}/scripts/worktree-new.sh {N}` then
   `${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh launch {N}` (one standalone
   `tmux new-session` per pick — never a `for`-loop wrapper; see Phase D step 4)
   in a fresh worktree golem. Update `pool.json` `slots` / `backlog_depth`.

1. **Repeat** until the backlog is empty and every slot is idle.

### Controls (mid-flight Surface commands)

These flip `pool.json` policy; the next sweep's refill honors it. They are also
exposed as `/orchestrate` invocations (see the table in SKILL.md):

- **`pool <N>`** — set the pool size live. **Grow** → free slots appear and the
  next sweep fills them. **Shrink** → the now-`excess` golems are left to
  **drain** (finish their PRs), never killed; the footprint settles at the new N.
- **`drain`** — set `accepting = "draining"`. Refills stop; in-flight golems run
  to completion and the pool idles. Use before a context reset / service restart
  / end of day. One-way intent (re-enable with `resume`).
- **`pause`** — set `accepting = "paused"`. Freeze refills without draining
  (slots are held open, not wound down).
- **`resume`** — set `accepting = "accepting"`. Re-enable refills; the next sweep
  fills any free slot.

`${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` surfaces the pool line — size, slots in use, backlog depth, and
the `accepting` state — above the golem table.

### Track composition (`mode: "tracks"`)

Where the flat pool refills from **global** priority, **tracks** pre-partition the
backlog into 2–4 ordered **lanes** run serially, so within-track collisions are
moot and cross-track collisions were minimized up front. Composition is the
**pure-computation `tracks` mode of `workflow.js`** (mirroring `pool` / `train` —
no poll, no I/O, no dispatch). It is the first step of the setup flow
(`autonomy-levels.md` § "The setup flow"): **propose** these tracks, **approve**
them, choose the **autonomy level**, then **dispatch** one golem per track head.

Call it with the same priority-ordered backlog the pool uses (each issue with its
predicted files — `## Affected Files` + `component/*` labels):

```text
args: {
  mode:       "tracks",
  backlog:    [{ issue, files: [<predicted paths>] }, …],  // next-issue priority order
  trackCount: <2..4>,   // desired lanes (clamped; default 3)
  trackSize:  <3..5>,   // max issues per lane (clamped; default 5)
}
```

It returns `tracks` = `{ tracks, deferred, cross_track_overlap, rationale }`:

- **`tracks`** — the composed lanes: `[{ lane, issues: [<ordered>] }]`. Each
  lane's `issues` are in priority order = the **serial execution order** (issue
  k+1 dispatches after issue k's PR merges). The greedy composition co-locates
  overlapping issues in one lane (which keeps *cross*-lane overlap low) and opens
  a fresh lane for work disjoint from every open lane while lanes remain. Priority
  is honored **fuzzily** — a higher-priority issue may be deferred to balance
  lanes and avoid collisions (explicitly desired).
- **`deferred`** — backlog issues that did not fit (all lanes full or capped), in
  priority order; a later composition sweep can pick them up.
- **`cross_track_overlap`** — count of lane pairs sharing ≥ 1 predicted file
  (lower is better — the objective the composition minimizes).
- **`rationale`** — short, deterministic, data-derived notes (lane count / sizes /
  deferred count / overlap) for the proposal the operator approves.

The composition persists to `.worktrees/.status/tracks.json` (schema:
`schemas/tracks.schema.json`) once approved, carrying the per-track
`autonomy_level` chosen at setup and a per-lane `head` pointer (the last-dispatched
issue).

**Lane-aware serial refill.** Once tracks are active, Phase P refill is
lane-scoped: a freed slot pulls **its own track's next queued issue** rather than
the global-priority winner. Each lane runs its issues **serially** — issue k+1
dispatches only after issue k's PR merges — so within-track collisions are moot
and the cross-track collisions were already minimized at composition. The live
session drives this by, on each sweep:

1. Noting which lanes freed a slot (a lane whose golem's PR merged), and advancing
   that lane's `head` in `tracks.json`.
2. Passing each open lane's **remaining** queue (the issues after `head`, with
   predicted files) as `tracks` and the freed lane indices as `laneSlots` to the
   `pool` mode call above.

The harness then, per freed lane slot, dispatches that lane's queue head — unless
it collides with in-flight or already-picked work, in which case it **holds the
slot** (serial order is preserved: it never skips ahead within a lane nor steals
another lane's work for that slot). A lane whose queue is **exhausted** (track
complete) contributes its slot to the **global collision-aware fallback** — the
same flat priority pick documented in the Refill loop above, which is also the
entire behavior for a plain `pool <N>` run with no tracks. So dispatch degrades
cleanly: lane-serial while a track has work, global-priority once it is drained.

### The setup flow (propose → approve → choose level → dispatch)

`mode: "tracks"` only **composes** the lanes; it never dispatches. Turning a
composition into running golems is the four-step **setup flow** from
`autonomy-levels.md` § "The setup flow" — two of the steps are human gates that
**wait indefinitely** (never lapse-and-default; see `autonomy-levels.md` §
*Standing rule*). Run it whenever the operator invokes `/orchestrate tracks` (or
`/orchestrate dispatch` with a track composition):

1. **Propose.** Render the composed lanes for the operator: for each lane, its
   ordered issue list (head first) with titles; the `deferred` issues; the
   `cross_track_overlap` count; and the `rationale` line. This is a display step,
   not a gate.

2. **Approve the tracks** — an `AskUserQuestion` gate. Offer **accept** /
   **adjust** (operator moves/drops an issue, or changes `trackCount`/`trackSize`
   → recompose and re-propose) / **regenerate** (recompose with the same params —
   the composition is deterministic, so "regenerate" is only meaningful after an
   adjust). **Wait indefinitely** for the answer; do not default to accept because
   the operator stepped away.

3. **Choose the rules of engagement** — a second `AskUserQuestion` gate offering
   the autonomy level **L1–L4**, each with its one-line description
   (`autonomy-levels.md` § "The four levels"). **Apply the critical cap when
   building the options:** a track containing a `severity/critical` issue offers
   **L1–L3 only** (never L4) — the cap holds its plan/escalation gates human. If
   tracks differ (one has a critical issue, another does not), ask **per track**,
   or ask once and record the capped value per track (L4 → L3 for the critical
   track, with a one-line note). **Wait indefinitely.**

4. **Dispatch.** Write the approved composition to
   `.worktrees/.status/tracks.json`, stamping each track's chosen (capped)
   `autonomy_level`. Then dispatch **one worktree golem per track head** at that
   level (Phase D — `scripts/worktree-new.sh {head}` + `scripts/golem-launch.sh
   launch {head}`, one bare `tmux new-session` per head); the rest of each track
   **queues** behind its head for lane-aware serial refill. Pass the level into
   the golem as `--level {N}` on its `/next-issue` prompt so the run's state file
   records it (see `next-issue/autonomous-mode.md` § *Level selection*).

**Autonomous orchestrator.** When the orchestrator itself runs unattended, the
two `AskUserQuestion` gates are authorized by the autonomous invocation (as the
train's batch approval is) — but the **critical cap still applies** (a critical
track never dispatches at L4), and any genuine escalation still stops. The
wait-indefinitely rule governs every non-autonomous run.

## Phase T — Integration Train

Land a **batch** of already-green, already-approved PRs end-to-end —
merge → rebase the next → merge — with **one up-front authorization** instead of
one human gate per merge/rebase/push, and with CI re-run cost bounded. This is
the automation of the merge→rebase→merge chain the human used to drive by hand
(see `merge-protocol.md` § *Integration Train — Sequencing & CI-Subset Policy*).

The train is **not** a new merge mechanism — it is **sequencing + batch
authorization** layered over the existing pieces: the order is computed by
`workflow.js` (`mode: 'train'`), each rebase is the existing Phase R
(`poll+rebase`), and every outward action still flows through the live session's
`ask` gates. The orchestrator still never merges a golem branch into its own.

1. **Assemble the batch.** Run Phase M and take the PRs that are merge-ready
   (`ci: passing`, `review: approved`/`none`, `blocking: false`) — or the
   explicit `<N…>` list. A PR that is not green + review-clean is **excluded**
   from the train (the train lands approved work; it does not wait on red CI or
   open review). Report the excluded PRs so the human sees what is held back.

1. **One up-front batch approval.** Authorize "**land this batch**" **once** via
   `AskUserQuestion` (skipped when autonomous — see below). This single consent
   replaces the per-step merge/rebase/push prompts. It does **not** dissolve the
   safety boundary: the outward-action `ask` rules on `git push` /
   `gh pr merge` / `gh pr create` remain in force for every individual action —
   the operator simply grants the batch once rather than N times.

1. **Compute the merge order.** Gather each PR's changed-file list
   (`gh pr view <N> --json files`) and invoke the Workflow tool on
   `~/.claude/skills/orchestrate/workflow.js` with:

   ```text
   args: {
     prs:  [{ number, branch, issue, golem, files: [<changed paths>] }, …],
     base: "<base branch, e.g. main>",
     mode: "train"
   }
   ```

   The harness returns `train` = `{ independents, chains, waves, order }`
   computed purely from pairwise file-overlap (no merge, no push, no rebase):

   - **`independents`** — PRs that share no changed file with any other; land in
     any order, **no rebase between them**.
   - **`chains`** — overlap components (≥2 PRs touching a common file), each
     ordered; land **in sequence**, rebasing each onto the prior merge.
   - **`waves`** — wave 0 = all independents + every chain head (mergeable
     immediately, in parallel); wave *k* = the *k*-th link of each chain (only
     mergeable after the (*k*−1)-th merges).

1. **Drive the loop** (loop-until-dry, resumable):

   1. **Merge wave 0** — every independent + each chain head. Prefer
      `gh pr merge <N> --auto --squash --delete-branch` so GitHub merges each the
      moment its already-green checks settle (no manual merge + wait); fall back
      to a direct `gh pr merge` where `--auto` is unavailable. Independents need
      no rebase, so they land without re-triggering CI.
   1. **For each chain, advance one link:** after the chain's current head
      merges, the next link is now behind base → run **Phase R**
      (`mode: "poll+rebase"`, scoped to that PR) to rebase it onto the new base.
      Post-#601 union handling resolves complementary same-region edits without
      escalation; only genuinely contradictory conflicts surface to the human.
   1. **Push** the rebased branch: `git push --force-with-lease origin <branch>`
      (the harness never pushes). Then merge it (`--auto` settle as above).
   1. **Repeat** until every wave is merged. Re-poll between waves to confirm CI
      stayed green and pick up any newly-behind PR.

1. **Bound CI cost.** A force-push after a rebase normally replays the full
   matrix. Reduce it per repo policy (see `merge-protocol.md`):

   - Use `gh pr merge --auto` so the PR merges on settle rather than after a
     manual wait — independents and no-conflict rebases add no full replay.
   - For a rebase whose only conflicts were docs/skills-only (union-resolved),
     require only the **changed-file** check subset to re-pass, not the whole
     build matrix, **where the repo's branch protection permits**.

   Auto-merge consent is unchanged: under an autonomous run the `--auto` fast
   path is taken only when BOTH `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` are
   set (see `ship-issue` § Environment Variables). The train's single batch
   approval does **not** substitute for that per-PR auto-merge consent.

1. **Honor stop/drain.** Between iterations, check the pool stop/drain signal —
   `pool.json` `accepting` (Phase P). If it is `draining` (or `paused`), finish
   the in-flight merge/rebase, then halt the train cleanly (leaving remaining PRs
   open and labeled) rather than starting the next wave. When `pool.json` is
   absent (the pool was never engaged), there is no drain signal and the train
   runs every wave to completion — the check defaults to "keep going."

1. **Report** the train result: merged PRs (with order/wave), rebases
   auto-resolved (with strategy), and any escalations surfaced **verbatim** for
   the human. Never merge a golem branch into the orchestrator branch.

**Autonomous train.** When the orchestrator runs autonomously, skip the
`AskUserQuestion` batch approval (the batch is authorized by the autonomous
invocation) but keep every outward-action `ask` gate and the `AUTOMERGE` +
`AUTOMERGE_AUTONOMOUS` double-consent. A genuine conflict escalation still stops
the train for the human — the train automates the *sequencing*, not the
judgment.
