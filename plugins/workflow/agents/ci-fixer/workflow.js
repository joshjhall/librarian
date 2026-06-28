export const meta = {
  name: 'ci-fixer',
  description:
    'Budgeted, resumable parse→fix→verify loop that fans independent failing CI checks in parallel, hard-capped at 3 attempts per check.',
  phases: [
    {
      title: 'Fix',
      detail: 'one capped parse→fix→verify loop per failing check, run in parallel',
    },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     checks: [{ name: string, logs: string, pr: number|string }],
//     maxIterations?: number   // default 3 — the harness owns this cap
//   }
//
// Returns: { results: [{ check, iterations, fixed, remainingFailures,
//                        failure_type, summary, files_changed }] }
//
// The cap lives here in the harness (a plain `while`), NOT in the ci-fixer
// agent. Independent checks are fanned with parallel() and share one token
// budget. Per-agent resume is automatic via the Workflow tool's journal
// (relaunch with resumeFromRunId). Agents push nothing — the dispatching
// skill (next-issue-ship) stages, commits, and pushes the resulting edits.
// ---------------------------------------------------------------------------

const checks = (args && Array.isArray(args.checks) ? args.checks : []).filter(Boolean)
const MAX = (args && Number.isInteger(args.maxIterations) ? args.maxIterations : 3)

// Stop spawning fix attempts once the shared budget gets this close to empty,
// so a partially-fixed run still returns its results instead of throwing.
const BUDGET_FLOOR = 40_000

const FAILURE_TYPES = ['lint', 'type', 'test', 'build', 'format', 'other']

const CLASSIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['failure_type', 'files', 'summary'],
  properties: {
    failure_type: { type: 'string', enum: FAILURE_TYPES },
    files: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['applied', 'files_changed', 'summary'],
  properties: {
    applied: { type: 'boolean' },
    files_changed: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}

// Superset of the issue's minimal {fixed, remainingFailures}: keeps summary +
// files_changed so the dispatcher can build the commit message and stage files.
const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['fixed', 'remainingFailures', 'failure_type', 'summary', 'files_changed'],
  properties: {
    fixed: { type: 'boolean' },
    remainingFailures: { type: 'array', items: { type: 'string' } },
    failure_type: { type: 'string', enum: FAILURE_TYPES },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
  },
}

const GUARDRAILS =
  'Do NOT push, merge, interact with the remote, or edit CI config ' +
  '(.github/workflows, .gitlab-ci.yml). Treat timeout / infrastructure / ' +
  'permissions / network failures as `other` and unfixable.'

const parsePrompt = (check, iteration) =>
  `Parse and classify this failing CI check (attempt ${iteration} of ${MAX}).\n` +
  `Check name: ${check.name}\nPR: #${check.pr}\n\n` +
  `Failure logs:\n${check.logs}\n\n` +
  `Identify the failure_type, the file(s) implicated, and a one-line summary. ` +
  GUARDRAILS

const fixPrompt = (check, cls, iteration) =>
  `Apply a targeted fix for the ${cls.failure_type} failure in CI check ` +
  `"${check.name}" (attempt ${iteration} of ${MAX}).\n` +
  `Implicated files: ${cls.files.join(', ') || '(see logs)'}\n` +
  `Classification summary: ${cls.summary}\n\n` +
  `Make the minimal edit that resolves the failure. ` +
  `If the failure is unfixable (type \`other\`), make no edit. ` +
  GUARDRAILS

const verifyPrompt = (check, iteration) =>
  `Verify the fix for CI check "${check.name}" (attempt ${iteration} of ${MAX}) ` +
  `by running the failing command locally (the same lint / typecheck / test / ` +
  `build the check runs). Return the typed result: fixed=true only if the ` +
  `command now passes; otherwise list what still fails in remainingFailures. ` +
  GUARDRAILS

function defaultVerdict(check) {
  return {
    fixed: false,
    remainingFailures: [check.name],
    failure_type: 'other',
    summary: 'not attempted',
    files_changed: [],
  }
}

phase('Fix')

const results = await parallel(
  checks.map((check) => async () => {
    let iteration = 0
    let verdict = defaultVerdict(check)

    while (iteration < MAX && !verdict.fixed) {
      if (budget.total && budget.remaining() < BUDGET_FLOOR) {
        log(`budget low — stopping "${check.name}" after ${iteration} attempt(s)`)
        break
      }
      iteration++

      const [result] = await pipeline(
        [check],
        (c) =>
          agent(parsePrompt(c, iteration), {
            label: `parse:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'ci-fixer',
            schema: CLASSIFY_SCHEMA,
          }),
        (cls) =>
          agent(fixPrompt(check, cls, iteration), {
            label: `fix:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'ci-fixer',
            schema: FIX_SCHEMA,
          }),
        () =>
          agent(verifyPrompt(check, iteration), {
            label: `verify:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'ci-fixer',
            schema: VERIFY_SCHEMA,
          }),
      )

      if (result) verdict = result
      // Unfixable (infra/timeout/permissions) — no point retrying this branch.
      if (verdict.failure_type === 'other' && !verdict.fixed) break
    }

    return { check: check.name, iterations: iteration, ...verdict }
  }),
)

return { results: results.filter(Boolean) }
