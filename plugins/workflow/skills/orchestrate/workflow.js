export const meta = {
  name: 'orchestrate-monitor',
  description:
    'Budgeted, resumable fan-out for the live orchestrator over the OPEN-PR set: (1) polls PR CI/review state + issue status labels as authoritative, with a per-PR checkpoint so a crashed sweep resumes mid-list; (2) optionally classifies PRs behind base and dispatches the rebase-agent to auto-resolve trivial conflicts, surfacing the rest for the human; (3) in train mode, computes a merge order from pairwise file-overlap (independent PRs in parallel waves, overlapping PRs serialized into chains) so the live session can land a batch with one approval; (4) in pool mode, computes a collision-aware refill plan for the fixed-size worker pool (which backlog issues fill free slots without predicted file-overlap with in-flight golems). All phases share ONE token budget. Pure computation in train and pool modes — never merges, never pushes, never dispatches a golem; never calls workflow() — the one Workflow nesting level is reserved for each golem process.',
  phases: [
    {
      title: 'Poll',
      detail: 'fan read-only PR-status reads across the open-PR set (parallel barrier, per-PR checkpoint)',
    },
    {
      title: 'Rebase',
      detail: 'classify PRs behind base; dispatch rebase-agent for trivial conflicts; collect resolved/escalated',
    },
    {
      title: 'Order',
      detail: 'train mode: compute merge order from pairwise file-overlap (parallel waves + serialized chains)',
    },
    {
      title: 'Pool',
      detail: 'pool mode: compute collision-aware backlog refill for free worker-pool slots (pure computation)',
    },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     prs: [{                 // the OPEN-PR set the orchestrator already enumerated
//       number: number,       // PR / MR number
//       branch: string,       // head branch (the golem's branch)
//       issue:  number,       // linked issue number (from "Closes #N" in the PR body)
//       golem?: string,       // golem id (agentNN / worktree label) — display + cache key only
//       files?: string[],     // changed-file paths (train mode); from `gh pr view --json files`.
//                             //   If omitted, train mode fetches it with a read-only poll agent.
//     }],
//     base: string,           // base branch the PRs target (default 'main')
//     mode: 'poll' | 'poll+rebase' | 'train' | 'pool',
//                             //   default 'poll'; 'poll+rebase' enables the Rebase phase;
//                             //   'train' computes a merge order (no poll, no rebase, no I/O);
//                             //   'pool' computes a collision-aware backlog refill plan
//                             //   for the fixed-size worker pool (no poll, no I/O)
//     maxRebases?: number,    // default = prs.length — the harness owns this cap
//
//     // --- pool mode only (see the Pool branch below) ---
//     pool?:     { size: number, accepting: 'accepting'|'draining'|'paused' },
//     inflight?: [{ issue, golem?, branch?, files?: string[] }], // current golems
//     backlog?:  [{ issue, files?: string[] }],   // candidates in priority order
//   }
//
// Returns:
//   {
//     base,
//     pr_status:   [PR_STATUS],     // poll / poll+rebase only; omitted in train/pool (pure compute)
//     rebases:     [REBASE_RESULT], // present only in poll+rebase mode
//     escalations: [{ pr, file, reason, ours_summary?, theirs_summary? }],  // poll+rebase only
//     train:       TRAIN,           // present only in train mode (merge-order plan)
//     pool:        POOL,            // present only in pool mode (refill plan)
//     budget_exhausted: boolean,
//     polled: number, rebased: number,
//   }
//   The train and pool branches return BEFORE the Poll phase, so they omit
//   pr_status / rebases / escalations entirely (not empty arrays). A caller that
//   reads those fields off a train/pool result must treat them as optional
//   (e.g. `result.pr_status ?? []`).
//
// The orchestrator session is LIVE/INTERACTIVE and is NOT this workflow — it
// INVOKES this harness for one bounded sweep, reads the result, refreshes its
// table, and takes the next human command. This harness never dispatches golems,
// never merges into the orchestrator branch, and never pushes: it returns results
// and the live orchestrator pushes rebased branches (--force-with-lease) under
// human supervision. PR + issue-label state are authoritative; the
// .worktrees/.status/*.json cache is consulted only to fill display gaps.
//
// TRAIN MODE is pure computation: it derives the *order* in which the live
// session should land an already-green, already-approved batch — PRs that share
// no changed files form independent "waves" (any order, no rebase between them);
// PRs that overlap on ≥1 file form a "chain" that must be landed in sequence,
// each rebased onto the prior merge (via Phase R). It performs NO merge, NO push,
// NO rebase — the live session drives those, gated, per SKILL.md Phase T.
// ---------------------------------------------------------------------------

const prs = (args && Array.isArray(args.prs) ? args.prs : []).filter(Boolean)
const base = args && typeof args.base === 'string' && args.base ? args.base : 'main'
const MODE =
  args && (args.mode === 'poll+rebase' || args.mode === 'train' || args.mode === 'pool')
    ? args.mode
    : 'poll'
const MAX_REBASES = args && Number.isInteger(args.maxRebases) ? args.maxRebases : prs.length

// Stop spawning fan-out work once the shared budget gets this close to empty, so
// a partially-complete sweep still returns its results instead of throwing
// mid-barrier. Matches the floor used by the ci-fixer / review harnesses.
const BUDGET_FLOOR = 40_000

// Conflict-class taxonomy — lifted verbatim from merge-protocol.md's
// "Conflict Classification for Cross-PR Rebase" decision tree. The first six
// are auto-resolvable by rebase-agent; the last three escalate to the human.
// `union` covers composable same-region edits — each side adds a distinct,
// non-contradictory change, so the agent keeps the superset of both rather than
// escalating (the general form of the `imports` combine rule).
const CONFLICT_CLASSES = [
  'lockfile',
  'generated',
  'imports',
  'union',
  'version',
  'whitespace',
  'logic',
  'add-add',
  'delete-modify',
]

// ---------------------------------------------------------------------------
// StructuredOutput schemas (typed gates — all additionalProperties:false).
// ---------------------------------------------------------------------------

// Authoritative per-PR state: PR/MR platform state wins over the status cache.
// label_state mirrors the live taxonomy owned by next-issue / next-issue-ship.
const PR_STATUS = {
  type: 'object',
  additionalProperties: false,
  required: ['pr', 'issue', 'branch', 'ci', 'review', 'label_state', 'behind_base', 'blocking', 'summary'],
  properties: {
    pr: { type: 'integer' },
    issue: { type: 'integer' },
    branch: { type: 'string' },
    ci: { type: 'string', enum: ['pending', 'passing', 'failing', 'none'] },
    review: { type: 'string', enum: ['none', 'changes-requested', 'approved', 'commented'] },
    label_state: {
      type: 'string',
      enum: ['in-progress', 'commit-pending', 'pr-pending', 'on-hold', 'none'],
    },
    behind_base: { type: 'boolean' },
    blocking: { type: 'boolean' },
    review_cycle: { type: 'integer', minimum: 0 },
    summary: { type: 'string' },
  },
}

// Cheap pre-classify before any rebase attempt: decides whether to dispatch the
// rebase-agent at all (none / trivial-only) or escalate the whole PR (has-logic).
const OVERLAP = {
  type: 'object',
  additionalProperties: false,
  required: ['pr', 'rebase_needed', 'conflict_files', 'overlap'],
  properties: {
    pr: { type: 'integer' },
    rebase_needed: { type: 'boolean' },
    conflict_files: { type: 'array', items: { type: 'string' } },
    overlap: { type: 'string', enum: ['none', 'trivial-only', 'has-logic'] },
  },
}

// Mirrors the rebase-agent's native {resolved, escalated} direct-mode contract
// exactly (see agents/rebase-agent/rebase-agent.md — the agent returns only
// these two fields). The harness stamps pr/branch/rebased onto the result after
// the agent returns; they are NOT agent-supplied, so they must not be required
// here or schema validation would force the agent to fabricate them.
const REBASE_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['resolved', 'escalated'],
  properties: {
    resolved: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'strategy'],
        properties: { file: { type: 'string' }, strategy: { type: 'string' } },
      },
    },
    escalated: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'reason'],
        properties: {
          file: { type: 'string' },
          reason: { type: 'string' },
          ours_summary: { type: 'string' },
          theirs_summary: { type: 'string' },
        },
      },
    },
  },
}

// Train mode: a PR's changed-file set, used to compute pairwise overlap. Only
// queried for PRs whose `files` the caller did not already supply.
const PR_FILES = {
  type: 'object',
  additionalProperties: false,
  required: ['pr', 'files'],
  properties: {
    pr: { type: 'integer' },
    files: { type: 'array', items: { type: 'string' } },
  },
}

// POOL is the harness's own return shape for pool mode (not an agent gate):
//   {
//     size: number,            // echoed target pool size
//     accepting: string,       // echoed 'accepting' | 'draining' | 'paused'
//     inflight_count: number,  // live golems at sweep time
//     free_slots: number,      // max(0, size - inflight_count)
//     picks: number[],         // issues to dispatch into free slots (collision-free,
//                              //   priority order). Empty when draining/paused.
//     held: [{ issue, reason }], // candidates skipped this sweep on predicted overlap
//     held_slots: number,      // free slots left unfilled (backlog dry / all colliding / not accepting)
//     excess: [{ issue, golem }], // golems beyond `size` after a shrink — let DRAIN, never kill
//   }
//
// TRAIN is the harness's own return shape for train mode (not an agent gate):
//   {
//     independents: number[],   // PRs sharing files with no other PR — land in any order, no rebase
//     chains: number[][],       // overlap components (size >= 2), each ordered by PR number;
//                               //   land in sequence, rebasing each onto the prior merge (Phase R)
//     waves: number[][],        // parallelizable batches: wave[0] = independents + every chain head;
//                               //   wave[k>0] = the k-th element of each chain long enough to have one
//     order: number[],          // one conservative linear landing order (independents, then chains flat)
//   }

const READONLY_POLL =
  'STRICTLY READ-ONLY: query PR/MR + issue state via gh/glab only. Do NOT edit, ' +
  'stage, commit, push, merge, rebase, or touch any git ref. Issue status labels ' +
  'and PR/MR state are authoritative; the .worktrees/.status/*.json cache may be ' +
  'stale — always prefer the live query.'

const REBASE_GUARDRAILS =
  'Operate ONLY on the PR head branch, rebasing it onto the base branch. Do NOT ' +
  'push, force-push, merge, open/close PRs, or touch the orchestrator branch — the ' +
  'live orchestrator pushes the rebased branch under human supervision. When both ' +
  'sides touched the same region, union complementary non-contradictory edits ' +
  '(keep the superset) before escalating. Escalate only genuinely contradictory ' +
  'conflicts (contradictory logic, contradictory add-add, or delete-modify) ' +
  'instead of guessing.'

const pollPrompt = (pr) =>
  `Report the current state of PR #${pr.number} (head branch "${pr.branch}", ` +
  `linked issue #${pr.issue}) targeting base "${base}".\n\n` +
  `Gather, via gh/glab: CI/checks rollup (pending/passing/failing/none), latest ` +
  `review decision (none/changes-requested/approved/commented), the issue's ` +
  `status/* label (in-progress/commit-pending/pr-pending/on-hold/none), whether ` +
  `the branch is behind "${base}" (base advanced since branch point), the number ` +
  `of observed review rounds, and whether the PR is blocking (needs human action: ` +
  `red CI, changes-requested, or merge conflicts). One-line summary. ` +
  READONLY_POLL

const overlapPrompt = (pr) =>
  `PR #${pr.number} (branch "${pr.branch}") is behind base "${base}". Without ` +
  `mutating anything, determine whether a rebase onto "${base}" is needed and ` +
  `classify the overlap of conflicting files: "none" (no conflicts), ` +
  `"trivial-only" (only lockfiles / generated / imports / version / whitespace, ` +
  `OR composable same-region edits whose two sides are complementary and ` +
  `non-contradictory — unionable, keep the superset; this includes a composable ` +
  `add-add where each side adds a distinct, non-conflicting block), or ` +
  `"has-logic" (any same-region conflict whose sides genuinely contradict and ` +
  `cannot be unioned — including a contradictory add-add — or any delete-modify ` +
  `conflict). List the conflicting files. ` +
  READONLY_POLL

const rebasePrompt = (pr, ov) =>
  `Rebase PR head branch "${pr.branch}" (PR #${pr.number}) onto base "${base}". ` +
  `Conflicting files: ${ov.conflict_files.join(', ') || '(detect during rebase)'}. ` +
  `Classify each conflict and apply the appropriate trivial strategy ` +
  `(${CONFLICT_CLASSES.slice(0, 6).join(' / ')}); for a same-region conflict, ` +
  `union complementary non-contradictory edits (keep the superset) before ` +
  `escalating; escalate only genuinely contradictory conflicts. ` +
  `Return resolved[] and escalated[]. ` +
  REBASE_GUARDRAILS

const filesPrompt = (pr) =>
  `List the changed files of PR #${pr.number} (head branch "${pr.branch}") ` +
  `targeting base "${base}". Use \`gh pr view ${pr.number} --json files\` (or the ` +
  `glab equivalent) and return the repo-relative path of every changed file. ` +
  READONLY_POLL

// Shared changed-file overlap predicate: do two file Sets share >= 1 path?
// Used by both train mode (overlap graph between PRs) and pool mode (collision
// check between a backlog candidate and in-flight golems). Iterate the smaller
// set for the cheaper membership scan.
const setsIntersect = (a, b) => {
  const [small, large] = a.size <= b.size ? [a, b] : [b, a]
  for (const f of small) if (large.has(f)) return true
  return false
}

// ---------------------------------------------------------------------------
// Pool mode — compute a collision-aware backlog refill plan for the fixed-size
//   worker pool. No poll, no rebase, no merge, no push, no dispatch: this branch
//   returns BEFORE the Poll phase, like train mode. The live session
//   (SKILL.md Phase P) consumes `pool` to drive the gated worktree-new + Phase D
//   dispatch into each free slot. The harness NEVER launches a golem.
//
// Collision avoidance is heuristic and conservative: a slot is held ONLY on a
// PREDICTED file overlap (candidate's predicted files vs an in-flight golem's
// files, OR vs an already-picked candidate this sweep) — never on mere unknown.
// A candidate with no predicted files is dispatchable but ranked LAST, so the
// pool prefers known-disjoint work and doesn't starve on pure uncertainty.
// ---------------------------------------------------------------------------
if (MODE === 'pool') {
  phase('Pool')

  const pool = (args && args.pool) || {}
  const size = Number.isInteger(pool.size) && pool.size >= 0 ? pool.size : 0
  const accepting =
    pool.accepting === 'draining' || pool.accepting === 'paused'
      ? pool.accepting
      : 'accepting'

  const inflight = (args && Array.isArray(args.inflight) ? args.inflight : []).filter(Boolean)
  const backlog = (args && Array.isArray(args.backlog) ? args.backlog : []).filter(Boolean)

  // Free slots = target size minus the live golem count (never negative).
  // Excess (size shrank below the live count via `pool <N>`) is reported so the
  // live session lets those golems DRAIN — the harness never kills a golem.
  const freeSlots = Math.max(0, size - inflight.length)
  const excess =
    inflight.length > size
      ? inflight.slice(size).map((g) => ({ issue: g.issue, golem: g.golem || null }))
      : []

  // In-flight changed-file footprint (union of every live golem's predicted
  // files). A backlog candidate overlapping this set would collide on rebase.
  const inflightFiles = new Set()
  for (const g of inflight) {
    if (Array.isArray(g.files)) for (const f of g.files) if (f) inflightFiles.add(f)
  }

  // Stable, deterministic candidate order: backlog priority order is the
  // caller's responsibility (next-issue severity x effort); within that we keep
  // the given order but float no-file ("unknown") candidates to the back so
  // known-disjoint work is preferred. No Date.now()/Math.random() (both banned).
  const withFiles = []
  const noFiles = []
  for (const c of backlog) {
    const files = Array.isArray(c.files) ? c.files.filter(Boolean) : []
    ;(files.length ? withFiles : noFiles).push({ issue: c.issue, files: new Set(files) })
  }
  const candidates = [...withFiles, ...noFiles]

  const picks = []
  const held = []
  // Files claimed by picks already made THIS sweep — a later pick must avoid
  // colliding with an earlier pick too, not just with in-flight golems.
  const claimed = new Set(inflightFiles)

  // Draining/paused: refill nothing. Still report free_slots/excess for display.
  if (accepting === 'accepting') {
    for (const c of candidates) {
      if (picks.length >= freeSlots) break
      // A candidate with predicted files that intersect in-flight OR an
      // earlier pick collides — hold it (record why); otherwise pick it and
      // claim its files. A no-file candidate never intersects, so it is always
      // dispatchable (ranked last above).
      if (c.files.size && setsIntersect(c.files, claimed)) {
        held.push({ issue: c.issue, reason: 'predicted file overlap with in-flight or picked work' })
        continue
      }
      picks.push(c.issue)
      for (const f of c.files) claimed.add(f)
    }
  }

  // Slots left empty after the pass (backlog exhausted, all-colliding, or not
  // accepting) — surfaced so the operator sees an idle slot is intentional.
  const heldSlots = accepting === 'accepting' ? Math.max(0, freeSlots - picks.length) : freeSlots

  return {
    base,
    pool: {
      size,
      accepting,
      inflight_count: inflight.length,
      free_slots: freeSlots,
      picks,
      held,
      held_slots: heldSlots,
      excess,
    },
    budget_exhausted: false,
    polled: 0,
    rebased: 0,
  }
}

// ---------------------------------------------------------------------------
// Train mode — compute a merge order from pairwise changed-file overlap.
//   No poll, no rebase, no merge, no push: this branch returns BEFORE the Poll
//   phase. The live session (SKILL.md Phase T) consumes `train` to drive the
//   gated merge -> rebase -> merge loop with one up-front batch approval.
// ---------------------------------------------------------------------------
if (MODE === 'train') {
  phase('Order')

  // Resolve each PR's changed-file set: prefer the caller-supplied `files`
  // (from `gh pr view --json files`), and only spend a read-only agent on the
  // PRs that arrived without one. Budget-aware like the poll phase.
  let trainBudgetExhausted = false
  const withFiles = await parallel(
    prs.map((pr) => async () => {
      if (Array.isArray(pr.files)) return { pr: pr.number, files: pr.files.filter(Boolean) }
      if (budget.total && budget.remaining() < BUDGET_FLOOR) {
        trainBudgetExhausted = true
        log(`budget low — skipped file-list fetch for PR #${pr.number} (treated as no-overlap)`)
        return { pr: pr.number, files: [] }
      }
      const r = await agent(filesPrompt(pr), { label: `files:#${pr.number}`, phase: 'Order', schema: PR_FILES })
      if (!r) log(`file-list fetch FAILED for PR #${pr.number} — treated as no-overlap this run`)
      return { pr: pr.number, files: r ? r.files.filter(Boolean) : [] }
    }),
  )

  const fileMap = new Map(withFiles.map((f) => [f.pr, new Set(f.files)]))
  // Stable PR-number order makes every derived structure deterministic — no
  // Date.now()/Math.random() (both banned in workflow scripts anyway).
  const ordered = [...fileMap.keys()].sort((a, b) => a - b)

  // Build the overlap graph: an edge between two PRs that share >= 1 changed
  // file (shared set-intersection predicate, also used by pool mode).
  const overlaps = (a, b) => setsIntersect(fileMap.get(a), fileMap.get(b))
  const adj = new Map(ordered.map((p) => [p, []]))
  for (let i = 0; i < ordered.length; i++) {
    for (let j = i + 1; j < ordered.length; j++) {
      if (overlaps(ordered[i], ordered[j])) {
        adj.get(ordered[i]).push(ordered[j])
        adj.get(ordered[j]).push(ordered[i])
      }
    }
  }

  // Connected components over the overlap graph. A singleton component is an
  // independent PR (no file collision); a component of size >= 2 is a chain that
  // must be landed in sequence (each rebased onto the prior merge).
  const seen = new Set()
  const components = []
  for (const start of ordered) {
    if (seen.has(start)) continue
    const stack = [start]
    const comp = []
    seen.add(start)
    while (stack.length) {
      const n = stack.pop()
      comp.push(n)
      for (const m of adj.get(n)) {
        if (!seen.has(m)) {
          seen.add(m)
          stack.push(m)
        }
      }
    }
    comp.sort((a, b) => a - b)
    components.push(comp)
  }
  components.sort((a, b) => a[0] - b[0])

  const independents = components.filter((c) => c.length === 1).map((c) => c[0])
  const chains = components.filter((c) => c.length > 1)

  // Waves: everything that can land without waiting on another PR's merge goes in
  // wave 0 (all independents + every chain's head). Subsequent waves carry the
  // k-th link of each chain — they only become mergeable after the (k-1)-th merges.
  const waves = []
  const maxChainLen = chains.reduce((m, c) => Math.max(m, c.length), 1)
  for (let k = 0; k < maxChainLen; k++) {
    const wave = []
    if (k === 0) wave.push(...independents)
    for (const c of chains) if (k < c.length) wave.push(c[k])
    wave.sort((a, b) => a - b)
    if (wave.length) waves.push(wave)
  }

  // A single conservative linear order, for callers that just want a list:
  // independents first (cheapest — no rebase), then each chain laid out in full.
  const order = [...independents, ...chains.flat()]

  return {
    base,
    train: { independents, chains, waves, order },
    budget_exhausted: trainBudgetExhausted,
    polled: 0,
    rebased: 0,
  }
}

// ---------------------------------------------------------------------------
// Phase 1 — Poll (parallel barrier; per-PR checkpoint via the Workflow journal).
// ---------------------------------------------------------------------------
phase('Poll')
let budgetExhausted = false

const statuses = (
  await parallel(
    prs.map((pr) => async () => {
      if (budget.total && budget.remaining() < BUDGET_FLOOR) {
        budgetExhausted = true
        log(`budget low — skipped poll of PR #${pr.number} (not in this sweep)`)
        return null
      }
      const s = await agent(pollPrompt(pr), {
        label: `poll:#${pr.number}`,
        phase: 'Poll',
        schema: PR_STATUS,
      })
      // A null here is an agent failure, NOT a budget skip (those returned
      // above). Log it so the PR doesn't silently vanish from the rendered
      // status table — a missing row reads as "merged/gone" to the human.
      if (!s) log(`poll FAILED for PR #${pr.number} — omitted from this sweep, re-poll to refresh`)
      return s
    }),
  )
).filter(Boolean) // null-resilience: a failed/skipped PR read drops out, the sweep continues

// ---------------------------------------------------------------------------
// Phase 2 — Rebase (only PRs the poll flagged behind base; loop-until-dry).
// ---------------------------------------------------------------------------
const rebases = []
const escalations = []

if (MODE === 'poll+rebase') {
  phase('Rebase')

  // Work list: PRs behind base, in PR order. Each is independently journaled, so
  // relaunching with resumeFromRunId resumes mid-list rather than from PR zero.
  const queue = statuses
    .filter((s) => s.behind_base)
    .map((s) => prs.find((p) => p.number === s.pr))
    .filter(Boolean)

  let i = 0
  while (i < queue.length && rebases.length < MAX_REBASES) {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      budgetExhausted = true
      log(`budget low — stopping rebase sweep after ${rebases.length} PR(s)`)
      break
    }
    const pr = queue[i++]

    const [result] = await pipeline(
      [pr],
      (p) =>
        agent(overlapPrompt(p), {
          label: `overlap:#${p.number}`,
          phase: 'Rebase',
          schema: OVERLAP,
        }),
      (ov) => {
        // Logic overlap (or a failed classify) → never auto-rebase; escalate.
        if (!ov || ov.overlap === 'has-logic' || !ov.rebase_needed) {
          // On a FAILED classify we have no file list, so a per-file escalation
          // map would be empty and the PR would surface nothing to the human —
          // it'd look quietly handled. Emit one synthetic whole-PR escalation in
          // that case so a classify failure is always visible.
          let escalated
          if (!ov) {
            escalated = [{ file: '(whole PR)', reason: 'overlap classify failed — manual rebase review' }]
          } else {
            escalated = ov.conflict_files.map((f) => ({
              file: f,
              reason: ov.overlap === 'has-logic' ? 'logic overlap — human review' : 'rebase not attempted',
            }))
          }
          return Promise.resolve({
            pr: pr.number,
            branch: pr.branch,
            rebased: false,
            resolved: [],
            escalated,
          })
        }
        // Trivial-only (or no-conflict) → dispatch the existing rebase-agent.
        // The agent returns only { resolved, escalated }; stamp pr/branch/rebased
        // so this path's result matches the escalation branch's shape above.
        // A null/skipped agent result stays null (the `if (result)` guard below
        // handles it).
        return agent(rebasePrompt(pr, ov), {
          label: `rebase:#${pr.number}`,
          phase: 'Rebase',
          agentType: 'rebase-agent',
          schema: REBASE_RESULT,
        }).then((r) => r && { pr: pr.number, branch: pr.branch, rebased: true, ...r })
      },
    )

    if (result) {
      rebases.push(result)
      for (const e of result.escalated) escalations.push({ pr: pr.number, ...e })
    }
  }
}

return {
  base,
  pr_status: statuses,
  rebases,
  escalations,
  budget_exhausted: budgetExhausted,
  polled: statuses.length,
  rebased: rebases.length,
}
