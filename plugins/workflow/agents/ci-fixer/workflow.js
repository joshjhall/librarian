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
// skill (ship-issue) stages, commits, and pushes the resulting edits.
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

// Every prompt leads with the constant GUARDRAILS (anchoring the safety contract
// BEFORE the untrusted CI-log payload — injection posture) and confines the
// volatile per-check data (logs, classification) to the tail, so the stable head
// of the prompt is byte-identical wherever the surrounding data allows and the
// cacheable prefix is not disturbed by log text moving around (#256).
//
// parsePrompt takes NO iteration argument: classification reads only the
// static, unchanging `check.logs`, so it runs ONCE per check (hoisted out of the
// retry loop — #493), not once per attempt. Only fixPrompt/verifyPrompt vary per
// iteration.
const parsePrompt = (check) =>
  GUARDRAILS +
  `\n\nParse and classify this failing CI check. ` +
  `Identify the failure_type, the file(s) implicated, and a one-line summary.\n` +
  `Check name: ${check.name}\nPR: #${check.pr}\n\n` +
  `Failure logs:\n${check.logs}`

const fixPrompt = (check, cls, iteration) =>
  GUARDRAILS +
  `\n\nApply a targeted fix for the ${cls.failure_type} failure in CI check ` +
  `"${check.name}" (attempt ${iteration} of ${MAX}). ` +
  `Make the minimal edit that resolves the failure. ` +
  `If the failure is unfixable (type \`other\`), make no edit.\n` +
  `Implicated files: ${cls.files.join(', ') || '(see logs)'}\n` +
  `Classification summary: ${cls.summary}`

const verifyPrompt = (check, iteration) =>
  GUARDRAILS +
  `\n\nVerify the fix for CI check "${check.name}" (attempt ${iteration} of ${MAX}) ` +
  `by running the failing command locally (the same lint / typecheck / test / ` +
  `build the check runs). Return the typed result: fixed=true only if the ` +
  `command now passes; otherwise list what still fails in remainingFailures.`

function defaultVerdict(check) {
  return {
    fixed: false,
    remainingFailures: [check.name],
    failure_type: 'other',
    summary: 'not attempted',
    files_changed: [],
  }
}

// Synthesized verdict for an iteration whose pipeline did NOT return a real
// agent verify verdict (a null parse/fix/verify, or an unclassified failure).
// `agentVerdict: false` is the marker applyResult() uses to keep the loop
// retrying — a transient failure is NOT proof the check is unfixable. Crucially,
// when stage 2 already applied a fix, its files_changed are preserved here so an
// applied-but-unverified edit is never dropped (the "silent working-tree
// mutation" bug). failure_type comes from the classify result when present.
function transientVerdict(check, cls, fix) {
  const applied = !!(fix && fix.applied)
  return {
    agentVerdict: false,
    fixed: false,
    remainingFailures: [check.name],
    failure_type: cls && cls.failure_type ? cls.failure_type : 'other',
    summary: fix && fix.summary ? fix.summary : 'transient agent failure — retrying',
    files_changed: applied && Array.isArray(fix.files_changed) ? fix.files_changed : [],
  }
}

// Wrap a verify-stage agent response for the pipeline: a real verdict is tagged
// `agentVerdict: true` so applyResult() knows it may end the loop; a null verify
// falls back to a transientVerdict that preserves stage 2's applied files_changed.
// Extracted so the agentVerdict-tagging (the crux of the loop-control fix) is
// directly unit-testable, since the stage closure that calls it cannot be.
function wrapVerify(v, check, cls, fix) {
  return v ? { ...v, agentVerdict: true } : transientVerdict(check, cls, fix)
}

// The classify memoization decision (#493): classify runs only when `cls` is not
// already a truthy, memoized result. A successful classify is cached and reused
// across every fix/verify iteration (dropping the per-iteration re-classify);
// a null classify is intentionally left uncached so it is re-attempted next
// iteration, preserving the pre-existing transient-retry semantics. Extracted so
// this decision — the crux of the #493 change — is directly unit-testable, since
// the per-check stage closure that calls it cannot be (two-runtime model).
function needsClassify(cls) {
  return !cls
}

// Fold one iteration's pipeline result into the carried verdict, returning the
// next verdict plus whether the loop should stop. This is the fix for the
// cause-conflation bug: only an agent-RETURNED verify verdict may end the loop,
// and it only ends it on a genuine `other` + !fixed. A null pipeline result or a
// synthesized transient verdict always retries (up to the harness cap).
function applyResult(prev, result) {
  // Null pipeline item (a stage threw / was skipped): purely transient. Keep the
  // prior verdict untouched and retry — do NOT let the default 'other' break out.
  if (!result) return { verdict: prev, stop: false }

  // A real agent verify verdict: adopt it (dropping the internal marker). Break
  // only on a genuine unfixable classification — never on the seeded default.
  if (result.agentVerdict === true) {
    const { agentVerdict, ...verdict } = result
    const stop = verdict.failure_type === 'other' && !verdict.fixed
    return { verdict, stop }
  }

  // Synthesized transient verdict: carry forward any applied files_changed so a
  // fix applied before a null verify is still reported, but keep retrying
  // (stop: false). Only let the transient's generic failure_type/summary
  // OVERWRITE prev when prev is still the seeded default ('not attempted') — a
  // prior real agent classification (e.g. 'lint' / 'still 3 errors in foo.js')
  // must not be downgraded to 'transient agent failure — retrying', which would
  // mislead the human-facing dead-end summary once the cap is hit.
  const prevIsSeeded = prev.summary === 'not attempted'
  return {
    verdict: {
      ...prev,
      failure_type: prevIsSeeded ? result.failure_type : prev.failure_type,
      summary: prevIsSeeded ? result.summary : prev.summary,
      files_changed:
        result.files_changed && result.files_changed.length ? result.files_changed : prev.files_changed,
    },
    stop: false,
  }
}

phase('Fix')

const results = await parallel(
  checks.map((check) => async () => {
    let iteration = 0
    let verdict = defaultVerdict(check)

    // Classify at most ONCE per check (#493), memoized across iterations. The
    // classify agent reads only `check.logs`, which never changes across
    // attempts, so a successful classification is computed on the first iteration
    // and REUSED for every fix/verify attempt — dropping the redundant re-classify
    // that used to fire once per iteration (up to MAX-1 wasted classify agents).
    // The memo is deliberately kept INSIDE the loop rather than hoisted fully
    // out: this preserves the pre-existing transient semantics unchanged — a
    // classify that returns null is NOT cached (an `agent()` call is not
    // deterministic; a null can be a transient parse/schema hiccup, not proof the
    // logs are unclassifiable), so it flows through transientVerdict/applyResult
    // and is retried up to the cap exactly as before, and it stays gated behind
    // the BUDGET_FLOOR check below (a near-empty budget skips the whole attempt,
    // classify included).
    let cls = null

    while (iteration < MAX && !verdict.fixed) {
      if (budget.total && budget.remaining() < BUDGET_FLOOR) {
        log(`budget low — stopping "${check.name}" after ${iteration} attempt(s)`)
        break
      }
      iteration++

      // Sequential (memoized classify →) fix → verify (not pipeline([check], ...)):
      // N is 1 here — the real fan-out is the outer parallel(checks.map(...)). Each
      // stage returns a typed object, never a bare null, so a transient AGENT
      // failure surfaces as data (retryable) rather than reverting to 'not
      // attempted'. The explicit try/catch (issue #265) keeps a thrown HARNESS bug
      // visible: pipeline() used to swallow it to null, which applyResult() then
      // treated as a transient and retried up to the cap — the exact conflation
      // that enabled the #259 retry bug. A code fault won't self-heal on retry, so
      // it STOPS the loop with an attributable summary.
      let result
      let fix = null
      try {
        // Classify only when not already memoized: a successful classify runs
        // once and is reused for every later iteration. A retried null re-enters
        // here on the next iteration. The `#${iteration}` label suffix stays (as on
        // the sibling fix/verify calls) so each genuine invocation on the retry
        // path keeps a unique journal key for resume (resumeFromRunId).
        if (needsClassify(cls)) {
          cls = await agent(parsePrompt(check), {
            label: `parse:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'workflow:ci-fixer',
            schema: CLASSIFY_SCHEMA,
          })
        }
        if (cls) {
          // Guard the classify result before fixPrompt dereferences it — a null
          // classify skips the fix agent.
          fix = await agent(fixPrompt(check, cls, iteration), {
            label: `fix:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'workflow:ci-fixer',
            schema: FIX_SCHEMA,
          })
        }
        if (!cls) {
          // Skip verify when nothing was classified/attempted — retried next iter.
          result = transientVerdict(check, cls, fix)
        } else {
          const v = await agent(verifyPrompt(check, iteration), {
            label: `verify:${check.name}#${iteration}`,
            phase: 'Fix',
            agentType: 'workflow:ci-fixer',
            schema: VERIFY_SCHEMA,
          })
          // A null verify preserves stage 2's applied files_changed so the edit
          // is never silently unreported.
          result = wrapVerify(v, check, cls, fix)
        }
      } catch (e) {
        // A harness bug threw (previously swallowed to null by pipeline()).
        // Report it as a code fault and STOP retrying — unlike an agent null, a
        // harness error is not transient. Preserve any edit this iteration's fix
        // stage already applied so it is still committed/reported.
        log(`ci-fixer harness error on "${check.name}#${iteration}" — ${e.message}`)
        verdict = {
          fixed: false,
          remainingFailures: [check.name],
          failure_type: 'other',
          summary: `harness error — ${e.message}`,
          files_changed:
            fix && fix.applied && Array.isArray(fix.files_changed) && fix.files_changed.length
              ? fix.files_changed
              : verdict.files_changed,
        }
        break
      }

      const step = applyResult(verdict, result)
      verdict = step.verdict
      // Stop only on a genuine agent-returned unfixable verdict — never on a
      // transient null / synthesized result (which consumes the iteration and
      // retries up to the cap).
      if (step.stop) break
    }

    return { check: check.name, iterations: iteration, ...verdict }
  }),
)

return { results: results.filter(Boolean) }
