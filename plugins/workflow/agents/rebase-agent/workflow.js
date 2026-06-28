export const meta = {
  name: 'rebase-agent',
  description:
    'Budgeted, resumable per-file conflict resolution: each conflicted file is its own classify → resolve → (regen) → re-test pipeline, fanned in parallel under ONE shared token budget with a per-file checkpoint so a death at file N resumes at N. Trivial mechanical conflicts auto-resolve; everything else escalates. Never calls workflow() — it may itself run inside another workflow (e.g. orchestrate cross-PR rebase), and the one nesting level is reserved.',
  phases: [
    {
      title: 'Resolve',
      detail: 'one classify→resolve→regen?→retest pipeline per conflicted file, run in parallel',
    },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     files: string[],     // conflicted-file paths (from the caller's merge/rebase)
//     into?: string,       // branch being merged INTO — lockfile "prefer ours" hint
//     maxFlakes?: number,  // default 3 — cap on flaky re-test retries per file
//   }
//
// Returns the rebase-agent's native aggregate contract (unchanged, so callers
// like orchestrate/workflow.js's REBASE_RESULT wrapper keep working):
//   {
//     resolved:  [{ file, strategy }],
//     escalated: [{ file, reason, ours_summary?, theirs_summary? }],
//   }
//
// The fan-out, the shared token budget, and per-file resume all live HERE in the
// harness — NOT in the rebase-agent. The agent is one `agentType: "rebase-agent"`
// driven in two discriminated modes named in the prompt: `classify` and
// `resolve`. A file whose pipeline throws drops to null and is reported as
// escalated; the rest proceed. The agent applies edits in the working tree; it
// never pushes — the caller stages/commits the result.
// ---------------------------------------------------------------------------

const files = (args && Array.isArray(args.files) ? args.files : []).filter(Boolean)
const INTO = args && typeof args.into === 'string' && args.into ? args.into : null
const MAX_FLAKES = args && Number.isInteger(args.maxFlakes) ? args.maxFlakes : 3

// Stop spawning work once the shared budget gets this close to empty, so a
// partially-resolved run still returns its results instead of throwing
// mid-barrier. Matches the floor used by the ci-fixer / review harnesses.
const BUDGET_FLOOR = 40_000

// Mechanical strategies the agent may auto-apply. Anything else → escalate.
// `union` covers composable same-region edits — each side adds a distinct,
// non-contradictory change, so the agent keeps the superset of both rather than
// escalating (the general form of the `imports` combine rule).
const STRATEGIES = ['lockfile', 'generated', 'imports', 'union', 'version', 'whitespace']

const CLASSIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['strategy', 'escalate', 'reason'],
  properties: {
    // strategy is meaningful only when escalate=false; 'logic' marks the
    // catch-all non-mechanical class that always escalates.
    strategy: { type: 'string', enum: [...STRATEGIES, 'logic'] },
    escalate: { type: 'boolean' },
    reason: { type: 'string' },
  },
}

const RESOLVE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['resolved', 'needs_regen', 'files_changed', 'summary'],
  properties: {
    resolved: { type: 'boolean' },
    // true only for lockfile/generated strategies — triggers the regen step.
    needs_regen: { type: 'boolean' },
    files_changed: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    // populated when the agent could not mechanically resolve after all
    ours_summary: { type: 'string' },
    theirs_summary: { type: 'string' },
  },
}

// regen + re-test verdict (one tool call covers both: re-run generator/package
// manager, then re-run the project's test/build to confirm the file is clean).
const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'flaky', 'summary'],
  properties: {
    ok: { type: 'boolean' }, // file resolves AND re-test passes
    flaky: { type: 'boolean' }, // re-test failed in a way worth one more try
    summary: { type: 'string' },
  },
}

const GUARDRAILS =
  'Operate ONLY on the one file named. Do NOT push, merge, touch other files, ' +
  'edit CI config, or call workflow(). Resolve only mechanical conflicts; when ' +
  'both sides touched the same region, union complementary non-contradictory ' +
  'edits (keep the superset) before escalating. Escalate genuinely ' +
  'contradictory logic / architecture / API / config conflicts.'

const classifyPrompt = (file) =>
  `Mode: classify. Inspect the conflict markers in "${file}" and classify the ` +
  `conflict. Choose strategy from: ${STRATEGIES.join(' / ')} (mechanical) or ` +
  `"logic" (anything requiring human judgment — set escalate=true). Lock files, ` +
  `generated files, import-ordering, and version bumps are mechanical. A same-` +
  `region conflict whose two sides are complementary and non-contradictory ` +
  `(each adds a distinct change — a new flag/arg/clause, an adjacent additive ` +
  `edit) is "union", not "logic": keep the superset of both. Only same-region ` +
  `edits that genuinely contradict (overlapping logic that can't coexist), API ` +
  `changes, and config changes escalate. ` +
  GUARDRAILS

const resolvePrompt = (file, cls) =>
  `Mode: resolve. Apply the "${cls.strategy}" strategy to "${file}"` +
  (INTO ? ` (prefer the "${INTO}" side for lockfiles, then regenerate)` : '') +
  `. Set needs_regen=true only for lockfile/generated strategies. If you cannot ` +
  `mechanically resolve it after all, set resolved=false and fill ours_summary ` +
  `+ theirs_summary so it can be escalated. ` +
  GUARDRAILS

const verifyPrompt = (file, cls, attempt) =>
  `Mode: resolve (verify, attempt ${attempt} of ${MAX_FLAKES}). For "${file}": ` +
  (cls.strategy === 'lockfile' || cls.strategy === 'generated'
    ? 'run the lockfile-only / script-free regeneration command (see the ' +
      'rebase-lockfile / rebase-generated skills) for this file, then '
    : '') +
  `confirm the file is clean. PREFER the most TARGETED check available — that ` +
  `the conflict markers are gone and the single file parses / type-checks / ` +
  `builds in isolation (e.g. compile just this module, lint just this file, or ` +
  `run only its own test target). Fall back to the full project test/build ONLY ` +
  `if no file-scoped check exists. Running the whole suite here is expensive and, ` +
  `because files are verified in parallel, can collide on shared ports / test ` +
  `databases — so scope it down when you can. Return ok=true only if it now ` +
  `passes; set flaky=true if the failure looks transient (and may have been a ` +
  `parallel-run collision) so a retry may help; otherwise flaky=false. ` +
  GUARDRAILS

phase('Resolve')

const resolved = []
const escalated = []

const outcomes = await parallel(
  files.map((file) => async () => {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      return { file, kind: 'escalated', reason: 'budget exhausted before classify' }
    }

    // classify → resolve → verify(regen + re-test), short-circuiting on escalate.
    const [outcome] = await pipeline(
      [file],
      (f) =>
        agent(classifyPrompt(f), {
          label: `classify:${f}`,
          phase: 'Resolve',
          agentType: 'rebase-agent',
          schema: CLASSIFY_SCHEMA,
        }),
      (cls) => {
        if (!cls || cls.escalate || cls.strategy === 'logic') {
          return Promise.resolve({
            file,
            kind: 'escalated',
            reason: cls ? cls.reason : 'classification failed',
          })
        }
        return agent(resolvePrompt(file, cls), {
          label: `resolve:${file}`,
          phase: 'Resolve',
          agentType: 'rebase-agent',
          schema: RESOLVE_SCHEMA,
        }).then((res) => ({ file, cls, res }))
      },
      async (step) => {
        // Already terminal (escalated) — pass through.
        if (step.kind === 'escalated') return step
        const { cls, res } = step
        if (!res || !res.resolved) {
          return {
            file,
            kind: 'escalated',
            reason: res ? res.summary : 'resolve failed',
            ours_summary: res ? res.ours_summary : undefined,
            theirs_summary: res ? res.theirs_summary : undefined,
          }
        }

        // Per-file checkpoint: regen + re-test, with a bounded loop-until-dry
        // over flaky re-tests. A regen/verify failure escalates THIS file only.
        let attempt = 0
        let verdict = null
        while (attempt < MAX_FLAKES) {
          if (budget.total && budget.remaining() < BUDGET_FLOOR) {
            log(`budget low — stopping verify for "${file}" after ${attempt} attempt(s)`)
            break
          }
          attempt++
          verdict = await agent(verifyPrompt(file, cls, attempt), {
            label: `verify:${file}#${attempt}`,
            phase: 'Resolve',
            agentType: 'rebase-agent',
            schema: VERIFY_SCHEMA,
          })
          if (!verdict) break
          if (verdict.ok) return { file, kind: 'resolved', strategy: cls.strategy }
          if (!verdict.flaky) break // hard failure — no point retrying
        }
        return {
          file,
          kind: 'escalated',
          reason: verdict ? verdict.summary : 'regen/re-test failed',
        }
      },
    )

    return outcome
  }),
)

for (const o of outcomes.filter(Boolean)) {
  if (o.kind === 'resolved') {
    resolved.push({ file: o.file, strategy: o.strategy })
  } else {
    escalated.push({
      file: o.file,
      reason: o.reason,
      ...(o.ours_summary ? { ours_summary: o.ours_summary } : {}),
      ...(o.theirs_summary ? { theirs_summary: o.theirs_summary } : {}),
    })
  }
}

return { resolved, escalated }
