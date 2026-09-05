
log(`review cycle ${CYCLE}/${MAX_CYCLES} (phase: ${PHASE})`)

// Reject an unrecognized input key before anything is dispatched (#597). This
// is deliberately the FIRST thing after the cycle banner: the failure costs no
// agent turns, and the caller learns at dispatch rather than after a full cycle
// has reported a hollow `clean: true`. See `unknownArgKeys` above for why a
// throw beats a clean-looking verdict.
//
// This lives in the orchestration body, not the pure prefix, on purpose: a
// column-0 `if (`/`throw` above the helpers would move the slice boundary that
// tests/lib/extract-helpers.mjs keys on (ORCH_BOUNDARY) and silently shrink the
// prefix every ship-issue helper test extracts.
const unknownKeys = unknownArgKeys(args)
if (unknownKeys.length > 0) {
  throw new Error(
    `review harness: unknown args key(s): ${unknownKeys.join(', ')} — ` +
      `accepted keys are: ${KNOWN_ARG_KEYS.join(', ')}. ` +
      'An unrecognized key is silently ignored, so the input it carried would be ' +
      'missing and this cycle could report a falsely clean review. Fix the key and re-dispatch.'
  )
}

// A cycle with neither a full diff nor a fix delta reviews nothing of its own
// accord (#597, AC#3). This is NOT an error: omitting `diff` is a documented
// supported mode — each reviewer then derives it in-agent via `git diff
// origin/main...HEAD`, which costs extra tool calls but still produces a real
// review (see pre-ship-validation.md). So it warns rather than throwing, and
// deliberately does not force `clean: false`, which would leave a legitimately
// diff-less run unable to ever terminate and would dead-end the PR at
// maxCycles. The point is that a DROPPED `diff` key and an INTENTIONALLY
// omitted one look identical from inside the harness — this line makes the
// condition visible in the log either way.
if (noDiffSupplied(scopeDiff, deltaDiff)) {
  log(
    'WARNING: no diff supplied (args.diff and args.deltaDiff both empty) — reviewers ' +
      'will derive the diff in-agent. If you meant to pass one, it was dropped or mistyped.'
  )
}

// Make the active bound observable: an unbounded run is the DEFAULT (#553), and
// must not look identical in the log to a bounded one.
if (budget.total) {
  log(`token bound: runtime turn budget (${budget.remaining()} remaining)`)
} else if (CYCLE_TOKEN_CEILING) {
  log(`token bound: caller ceiling ${CYCLE_TOKEN_CEILING} output tokens for this cycle`)
} else {
  log('token bound: none (default) — measuring only; pass args.tokenCeiling to bound')
}

// Pre-scan handoff (#556): say when it did NOT arrive. The scanner runs at
// Step 3.5 item 5 regardless, so a missing handoff means its output was
// computed and thrown away — silent, and indistinguishable from a clean scan.
if (preScan.length > 0) {
  log(
    `pre-scan: ${preScan.length} candidate(s) supplied` +
      (preScanTruncated > 0 ? ` (${preScanTruncated} omitted for size)` : '')
  )
} else {
  log('pre-scan: none supplied — reviewers will re-derive mechanical findings (pass args.preScan)')
}
if (conventionsDigest) {
  log(`conventions digest: ${conventionsDigest.length} chars${conventionsDigestTruncated ? ' (truncated)' : ''}`)
} else {
  log('conventions digest: none supplied — reviewers will re-read CLAUDE.md/memory (pass args.conventionsDigest)')
}

// --- Manifest ---------------------------------------------------------------
phase('Manifest')

// Dispatched through `attempt` so a THROW is reported as a cycle result rather
// than crashing the script (#646). `agent()` fails two ways — a terminal API
// error returns null, StructuredOutput retry-cap exhaustion throws — and #616's
// bare `if (!manifest)` guard only ever saw the first. The throw is if anything
// the MORE common one: it was the observed failure both times.
const manifestAttempt = await attempt(
  () =>
    agent(manifestPrompt(), {
      label: 'manifest',
      phase: 'Manifest',
      agentType: 'dev-core:code-reviewer',
      schema: MANIFEST_SCHEMA,
    }),
  'manifest'
)

if (!manifestAttempt.ok) {
  // The manifest is a single point of failure ahead of the whole fan-out, so its
  // death means NO dimension ever ran — the cycle produced zero review signal.
  // Flag it as such (5th arg) so the convergence helper does not charge it to
  // REVIEW_MAX_CYCLES: this is the exact failure observed on PR #615, where a
  // schema-validation failure repeated identically across all five retries and
  // burned a cycle slot having reviewed nothing (#616).
  const r = emptyResult(
    false,
    // Names which failure fired, so the next person debugging this does not have
    // to read a transcript to tell a null return from a caught throw (#646 AC3).
    manifestFailureNote(manifestAttempt.threw, manifestAttempt.error),
    [],
    0,
    true
  )
  // A failed manifest is not a clean pass: do not let the skill stop the loop
  // on a degenerate cycle.
  r.clean = false
  return r
}

const manifest = manifestAttempt.value

// --- Review (dimensions as ONE barrier under one budget) --------------------
phase('Review')

// Reused + new dimensions, narrowed to the fix delta on a re-review cycle (#492):
// selectReviewDimensions returns the entries to run (each with the diff it reads —
// delta for delta-local dimensions, full for scope-drift), plus the budget-floor
// skip bookkeeping. `dimensionsSkipped`/`budgetExhausted` still mean a GENUINE
// partial cycle (a dimension that should have run hit the budget floor); a
// dimension dropped because the delta didn't touch it is simply absent, not a
// partial-cycle signal. The selector logs are minimal, so surface a narrowing note
// for the operator.
const narrowed = narrowingActive(CYCLE, deltaDiff, deltaFiles)
if (narrowed) {
  log(`re-review cycle ${CYCLE} narrowed to fix delta (${deltaFiles.length} file(s)); scope-drift keeps full diff`)
}
// Doc-only routing (#550). Surface it before the selector runs so a routed
// cycle is never silently indistinguishable from a full one in a transcript —
// the same reason the narrowing note and the `token bound:` line exist.
if (reviewRoute === 'cheap') {
  log(
    `review route: cheap (doc-only diff) — running only the dimensions whose ` +
      `DIMENSION_RELEVANT_TYPES entry claims docs, plus scope-drift. This cycle ` +
      `is complete-by-design, NOT partial: it can still return clean.`
  )
}
const selected = selectReviewDimensions({
  cycle: CYCLE,
  fullDiff: scopeDiff,
  deltaDiff,
  deltaFiles,
  priorBlocking: priorBlockingDimensions,
  manifest,
  budget: reviewBudget,
  budgetFloor: BUDGET_FLOOR,
  reusedDimensions: REUSED_DIMENSIONS,
  newDimensions: NEW_DIMENSIONS,
  route: reviewRoute,
})
let budgetExhausted = selected.budgetExhausted
// Names of dimensions that never ran this cycle — skipped at build time (budget
// floor) or nulled mid-barrier (agent threw / budget ran out). Any non-empty
// list means the cycle is PARTIAL; it is surfaced as `dimensions_skipped` so the
// skill can report which dimensions were missed, and it always accompanies
// `budgetExhausted` (the flag `clean` actually gates on). Narrowing does NOT add
// to it (a delta-irrelevant dimension is complete-by-design, not missed).
const dimensionsSkipped = selected.dimensionsSkipped.slice()
for (const name of dimensionsSkipped) log(`budget low — skipping dimension "${name}"`)
const dimensions = selected.entries
// Conditional specialists from the manifest (reuse code-reviewer's own modes).
// The manifest was built over the delta on a narrowed cycle, so `needs` already
// reflects the fix delta. `includeSpecialist` adds the prior-blocking carry-over
// (AC#3): on a narrowed cycle a specialist that blocked last cycle re-runs even if
// the fix touched no file of its type (manifest.needs false). The diff it reads
// follows the same rule as the delta-local dimensions via `diffForInclusion`: a
// specialist pulled in by manifest.needs (the delta touches its type) reads the
// delta; one pulled in ONLY by prior-blocking reads the FULL diff so it can
// re-confirm a finding that may live outside the delta. On a full cycle it reduces
// to the plain manifest.needs gate reading the full diff, unchanged. Budget-floor
// gating is unchanged.
const priorBlockingSet = new Set(priorBlockingDimensions)
const conditional = []
// On a cheap route no specialist runs: `database`/`devops` are gated on
// manifest.needs, set from database/ci/docker file types — none of which a
// doc-only diff can classify. Skipping the loop outright rather than trusting
// that arithmetic keeps the route's guarantee a property of ONE branch instead
// of an emergent consequence of the classifier and the manifest agent
// agreeing. Like the dimension path, this adds nothing to dimensionsSkipped.
for (const name of reviewRoute === 'cheap' ? [] : ['database', 'devops']) {
  const needs = !!manifest.needs[name]
  if (!includeSpecialist(name, needs, priorBlockingSet, narrowed)) continue
  const prior = narrowed && priorBlockingSet.has(name)
  // "touches" for a specialist is manifest.needs (whether the delta still
  // classifies a file of its type); pass it to diffForInclusion so a
  // prior-blocking-only specialist reads the full diff.
  const diff = diffForInclusion(narrowed, needs, prior, scopeDiff, deltaDiff)
  conditional.push({ name, mode: name, category: name, diff })
}
for (const d of conditional) {
  if (reviewBudget.total && reviewBudget.remaining() < BUDGET_FLOOR) {
    budgetExhausted = true
    dimensionsSkipped.push(d.name)
    log(`budget low — skipping conditional specialist "${d.name}"`)
    continue
  }
  dimensions.push({ kind: 'reused', dim: d, diff: d.diff })
}

const reviewResults = await parallel(
  dimensions.map((entry) => () => {
    // Re-check the ceiling INSIDE the thunk, not just at build time above.
    // parallel() invokes thunks as slots free up, so a barrier built when the
    // budget was healthy can still have later thunks start after it drained.
    // With a runtime-armed budget the runtime throws and parallel() nulls the
    // result; a caller-supplied CYCLE_TOKEN_CEILING is SOFT — nothing throws —
    // so without this check it would bound nothing once the barrier is built.
    // Returning null here lands in the SAME partial-cycle path as a thrown
    // agent below (budgetExhausted + dimensionsSkipped + clean forced false).
    if (reviewBudget.total && reviewBudget.remaining() < BUDGET_FLOOR) return null
    const prompt =
      entry.kind === 'new'
        ? newReviewerPrompt(entry.dim, manifest, entry.diff)
        : reusedReviewerPrompt(entry.dim, manifest, entry.diff)
    return agent(prompt, {
      label: `review:${entry.dim.name}`,
      phase: 'Review',
      agentType: 'dev-core:code-reviewer',
      schema: FINDINGS_SCHEMA,
    }).then((r) => ({ dim: entry.dim.name, findings: (r && r.findings) || [] }))
  })
)

const rawFindings = []
reviewResults.forEach((res, i) => {
  if (!res) {
    // A null result means the dimension never produced findings: its agent
    // threw (runtime budget exhausted mid-barrier, or any other terminal
    // failure — parallel() nulls both), OR the in-thunk ceiling check above
    // declined to spend. Either way the cycle is now PARTIAL: mark it exhausted
    // so a finding the judge never returned a verdict for defaults to deferrable
    // (filed, never dropped) and `clean` is forced false — the skill must not
    // treat a half-reviewed cycle as a clean pass (#270).
    budgetExhausted = true
    dimensionsSkipped.push(dimensions[i].dim.name)
    log(
      `dimension "${dimensions[i].dim.name}" did not complete (failed or budget-skipped) — ` +
        `continuing without its findings (cycle now partial)`
    )
    return
  }
  for (const f of res.findings) rawFindings.push({ ...f, dimension: res.dim })
})

// --- Comments (pr-cycle only: fold open PR review comments) -----------------
const commentsAddressed = []
if (PHASE === 'pr-cycle' && prComments.length) {
  phase('Comments')
  const triage = await tailAgent(
    () =>
      agent(commentsPrompt(manifest), {
        label: 'comment-triage',
        phase: 'Comments',
        agentType: 'dev-core:code-reviewer',
        schema: COMMENTS_SCHEMA,
      }),
    'comment-triage'
  )
  if (triage) {
    // Dedup by id (compared as strings): a triage response that repeats an id
    // must not push its addressed entry or finding twice (#261).
    const seenIds = []
    for (const t of triage.triaged) {
      if (seenIds.some((s) => sameCommentId(s, t.id))) continue
      seenIds.push(t.id)
      commentsAddressed.push({ id: t.id, disposition: t.disposition, note: t.note })
      // A blocking/deferrable comment with a concrete finding joins the stream
      // so it is rescored + classified like any other finding.
      if (t.finding && (t.disposition === 'blocking' || t.disposition === 'deferrable')) {
        rawFindings.push({ ...t.finding, dimension: 'review-comment', comment_id: t.id })
      }
    }
  } else {
    // Triage skipped/failed: comments stay unresolved AND the cycle is now
    // partial — mark it so it can never terminate the loop as a clean pass.
    budgetExhausted = true
    log('comment-triage failed — PR comments left unresolved for this cycle')
  }
}

// Unresolved comments (no disposition, or triage failed) keep the loop honest:
// the skill checks comments_addressed against the full comment set.
const unresolvedComments = prComments.length
  ? prComments.filter((c) => !commentsAddressed.some((a) => sameCommentId(a.id, c.id)))
  : []
if (unresolvedComments.length) {
  log(`${unresolvedComments.length} PR comment(s) not yet resolved-or-deferred`)
}

// Did this cycle produce NO review signal? See `computeAllDimensionsFailed`
// (before ORCH_BOUNDARY) for the predicate, what each clause is for, and the
// five ways it has been got wrong. It lives there rather than inline here so the
// truth table in tests/workflow-helpers/ship-issue.mjs exercises the REAL
// predicate instead of a reimplementation that can drift from it.
const allDimensionsFailed = computeAllDimensionsFailed(reviewResults, dimensionsSkipped)

if (rawFindings.length === 0) {
  // Comments and the unresolved count are passed IN rather than spliced onto the
  // returned object afterwards (#636): a post-hoc `r.clean = …` is a derivation
  // living past ORCH_BOUNDARY, where no unit test can reach it. Handing them to
  // the constructor means `clean` is computed by the same tested helper on this
  // path as on the findings-present one — a budget-truncated cycle (some
  // dimension never ran) is partial and must not read as clean, even when the
  // dimensions that DID run found nothing.
  return emptyResult(
    budgetExhausted,
    'no findings this cycle',
    dimensionsSkipped,
    dimensions.length,
    allDimensionsFailed,
    commentsAddressed,
    unresolvedComments.length
  )
}

// Stamp a UNIQUE, stable ref onto every finding now that the full set is
// assembled (review dimensions + folded PR comments). The index guarantees
// uniqueness even when file+line+category collide, so the judge can key its
// certainty + nature verdicts back without one finding overwriting another's.
rawFindings.forEach((f, i) => {
  f.ref = `${f.file}:${f.line_start}:${f.category}#${i}`
})

// --- Judge (one fresh pass: re-score certainty AND characterize nature) ---
// One tail agent does what were two separate ones — rescore + characterize.
// Merging them halves the judge tail cost per cycle (#491) while keeping the
// no-producer-self-grading property (this judge did not produce the findings).
// The blocking-vs-deferrable decision itself is NOT made here: `dispositionOf`
// computes it from this agent's two observations (#580).
phase('Judge')

const judged = await tailAgent(
  () =>
    agent(judgePrompt(rawFindings, budgetExhausted), {
      label: 'judge',
      phase: 'Judge',
      agentType: 'dev-core:code-reviewer',
      // Pin the fresh judge to opus: it is the last gate before a finding is
      // surfaced — its re-scored certainty and its `nature` call are the two
      // inputs `dispositionOf` uses to decide what stops a ship, so a
      // misjudged nature is now exactly as consequential as a misjudged
      // certainty. The accuracy that matters here
      // comes from judging in a fresh context that did not produce the
      // findings, not from the tier; opus delivers it at a fraction of fable's
      // cost on a gate that fires up to MAX_CYCLES times per issue (#526).
      model: 'opus',
      schema: JUDGE_SCHEMA,
    }),
  'judge'
)

if (!judged) {
  // Judge skipped/failed: applyJudgeVerdicts keeps producer certainty and forces
  // the cycle partial (budgetExhausted) so unclassified findings default to
  // deferrable (filed, never dropped) and `clean` stays false — a cycle that
  // never ran its judge must not read as clean. The tail floor (TAIL_FLOOR) is
  // below the fan-out floor, so the judge can be budget-skipped; without this the
  // truncated cycle could read as clean, breaking the "clean is unforgeable by
  // truncation" invariant (#270). Matches the comment-triage fallback here and
  // the code-reviewer rescore fallback.
  log('judge step failed — keeping producer certainty and applying default dispositions')
}

// Apply the judge's re-scored certainty + dispositions and partition the findings.
// The helper mutates each finding's certainty in place and, on a null judge,
// flips budgetExhausted true — so read it back for the `clean` computation below.
const applied = applyJudgeVerdicts(rawFindings, judged, budgetExhausted)
const { blocking, deferrable } = applied
budgetExhausted = applied.budgetExhausted

// Surface the cycle's cost in the log as well as the return value, so it is
// visible when watching a run without parsing the result JSON (#553).
log(`cycle output: ${reviewBudget.spent()} tokens across ${dimensions.length} dimensions`)

// Assemble the cycle result through the SINGLE constructor shared with the
// zero-findings path (#636). Everything past ORCH_BOUNDARY is unreachable by
// tests/lib/extract-helpers.mjs, so every derivation this return used to perform
// inline — the by_severity tally, the two #613 distributions, `clean` — now
// happens inside `buildResult`, where it is unit-tested. What is left here is a
// call whose arguments a reader can eyeball, and which
// tests/workflow-helpers/ship-issue/10-result-construction.mjs pins literally
// against the raw source, since this one line is still past the boundary.
return buildResult({
  rawFindings,
  blocking,
  deferrable,
  commentsAddressed,
  unresolvedLen: unresolvedComments.length,
  budgetExhausted,
  dimensionsSkipped,
  dimensionsRun: dimensions.length,
  noReviewSignal: allDimensionsFailed,
})
