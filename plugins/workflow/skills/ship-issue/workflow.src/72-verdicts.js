
// A finding's stable, UNIQUE id. file:line_start:category alone collides when
// two findings share a file+line+category (e.g. two correctness findings on the
// same line), which would make the judge silently overwrite one finding's
// certainty + disposition with the other's. The trailing index disambiguates; it
// is stamped onto each finding (as `.ref`) before the judge runs so the judge
// keys its verdicts off the exact same id we read back.
const refOf = (f) => f.ref

// The disposition policy (#580), as an ORDERED first-match rule list over the
// judge's observations plus the finding's own fields. Pure, total, and mutually
// exclusive by construction: exactly one rule matches any input, because R8 has
// no condition. That is the whole point — the policy it replaces was two
// overlapping prose predicates where DEFERRABLE's `OR severity ∈ {medium, low}`
// claimed the entire band producers actually emit, making `blocking` unreachable
// (1 firing in 67 findings across 26 cycles).
//
// Two deliberate design choices, both load-bearing:
//
//   1. Severity is DEMOTED to the R1 carve-out. It is not the primary axis and
//      must not become one again. The #567 evidence is that producers emit
//      `medium`/`low` almost exclusively, so ANY policy gated on critical/high
//      severity is unsatisfiable regardless of how many clauses it grows. The
//      discriminator that the six missed defects (#544, #549, #555 x2, #568 x2)
//      actually shared was "a live defect in code this PR just wrote" — which is
//      `nature`, not severity.
//
//   2. Rule ORDER is the semantics for every pair whose conditions can BOTH
//      hold. R2 (LOW certainty defers) sits above the nature rules so an
//      unconfident finding never blocks on nature alone; R3 above R4 so a
//      confirmed security finding blocks even when characterized as an
//      improvement; R6 above R7 so incomplete work is not deferred for being
//      large. Reordering any of those changes behavior, and
//      tests/workflow-helpers/ship-issue.mjs pins each by asserting the
//      deciding rule on a cell where the two compete.
//
//      R1 and R2 are the exception: their conditions are mutually exclusive
//      (`level !== 'LOW'` vs `level === 'LOW'`), so their relative order is NOT
//      load-bearing and swapping them is a genuine no-op. Do not read the pinned
//      cases as proof that every adjacent swap is caught — that pair cannot be
//      caught because there is no behavioral difference to catch.
//
// Returns `{ disposition, rule }`; `rule` names the deciding rule so the reason
// is attributable in a result and assertable in a test.
const dispositionOf = (finding, nature) => {
  const level = finding?.certainty?.level
  // R1: a critical-severity finding blocks unless we are unsure it is real. The
  // one place severity still leads — a critical defect should not wait on nature.
  if (finding?.severity === 'critical' && level !== 'LOW') {
    return { disposition: 'blocking', rule: 'R1-critical' }
  }
  // R2: LOW certainty always defers — filed, never dropped, never blocking. Above
  // the nature rules so a speculative "defect" cannot stop a ship.
  if (level === 'LOW') return { disposition: 'deferrable', rule: 'R2-low-certainty' }
  // R3: a confirmed security finding blocks at any severity (carried from the
  // old policy — the ONE carve-out that ever fired in the #567 batch).
  if (finding?.category === 'security' && level === 'HIGH') {
    return { disposition: 'blocking', rule: 'R3-security-high' }
  }
  // R4: not a defect — file it. Covers out-of-scope enhancements and style.
  if (nature === 'improvement') return { disposition: 'deferrable', rule: 'R4-improvement' }
  // R5: a real defect, but this PR did not write it. Fixing it here is scope
  // creep; it earns its own issue.
  if (nature === 'defect-in-preexisting-code') {
    return { disposition: 'deferrable', rule: 'R5-preexisting' }
  }
  // R6: the PR does not do what it claims. Blocks regardless of effort — an
  // unaddressed acceptance criterion means the work is not done, and no amount
  // of remaining effort converts "incomplete" into "shippable".
  if (nature === 'incomplete-work') return { disposition: 'blocking', rule: 'R6-incomplete' }
  // R7: a large fix is its own issue even when the defect is real and in new
  // code. Below R6 on purpose: incompleteness is not deferrable by size.
  if (finding?.effort === 'large') return { disposition: 'deferrable', rule: 'R7-large-effort' }
  // R8: what remains is a defect-in-new-code at MEDIUM or HIGH certainty with a
  // tractable fix — the exact class that was deferred six times running. It
  // blocks. Unconditional, so the rule list is total.
  return { disposition: 'blocking', rule: 'R8-defect-in-new-code' }
}

// Apply one fresh-judge result to the assembled findings and partition them into
// blocking vs deferrable — the core of the merged Judge stage (#491), extracted
// here (before the orchestration body, like `computeClean`) so the single-pass
// invariant is unit-testable. It MUTATES each finding's `certainty` in place (the
// re-scored level/confidence) and returns `{ blocking, deferrable,
// budgetExhausted }`:
//   - success (`judged` truthy): certainty AND nature are read from the SAME
//     verdict object, keyed by `ref`, and the disposition is then computed by
//     `dispositionOf` from the re-scored certainty — so certainty and nature can
//     never come from different verdicts, and the policy sees the re-scored
//     value rather than the producer's. A finding whose ref the judge omitted
//     keeps producer certainty and falls to the default disposition below.
//   - failure (`judged` null — budget-skipped or threw): certainty is left at the
//     producer value and `budgetExhausted` is forced true, so the cycle is PARTIAL
//     and can never read as clean (#270), matching the old two-stage fallbacks.
//   - default disposition for any finding with no judge disposition: `deferrable`
//     when the budget was exhausted (file it, never drop) else `blocking` (an
//     unclassified finding is surfaced, not silently ignored).
// `budgetExhausted` is returned (not just read) because the null-judged path flips
// it, and the caller's `clean` computation must see that flip.
const applyJudgeVerdicts = (rawFindings, judged, budgetExhausted) => {
  const dispByRef = new Map()
  if (judged) {
    const verdictByRef = new Map(judged.verdicts.map((v) => [v.ref, v]))
    for (const f of rawFindings) {
      const v = verdictByRef.get(refOf(f))
      if (v) {
        f.certainty = { ...f.certainty, level: v.certainty.level, confidence: v.certainty.confidence }
        // Compute AFTER the certainty write above: the policy keys off the
        // re-scored level, not the producer's (#580).
        const d = dispositionOf(f, v.nature)
        // Stamp the deciding rule onto the finding so a surfaced blocking
        // finding can say WHY it blocks — the old prose policy left that
        // unattributable, which is part of why 26 cycles of `blocking: []` went
        // unquestioned.
        f.disposition_rule = d.rule
        // Retain the judge's `nature` observation (#613). NOTHING downstream
        // reads it — the disposition was already computed above — it exists so
        // the value the policy keys off is auditable after the fact.
        //
        // `disposition_rule` is not a substitute for it. Only R4/R5/R6 name a
        // nature; R1/R2/R3/R7/R8 short-circuit before or around the nature
        // checks, so a finding either of those decided has an unrecoverable
        // nature. R2 and R8 are the two highest-volume rules, which would leave
        // most findings uncountable — and an unmeasurable `nature` is precisely
        // how a systematic miscall would stay as invisible as the failure #580
        // fixed.
        f.nature = v.nature
        dispByRef.set(refOf(f), d.disposition)
      }
    }
  } else {
    budgetExhausted = true
  }
  const blocking = []
  const deferrable = []
  for (const f of rawFindings) {
    const disp = dispByRef.get(refOf(f)) || (budgetExhausted ? 'deferrable' : 'blocking')
    if (disp === 'deferrable') deferrable.push(f)
    else blocking.push(f)
  }
  return { blocking, deferrable, budgetExhausted }
}

// The per-cycle `clean` predicate, shared by BOTH return paths (the
// empty-findings early return and the final classified return). A cycle is clean
// only when nothing blocks, every PR comment is resolved-or-deferred, AND the
// cycle was complete (`!budgetExhausted` — no dimension skipped at build time or
// nulled mid-barrier). Extracting it here — before the orchestration body — keeps
// the merge-invariant guard unit-testable at every site (a budget-truncated
// cycle can never read as clean, even with findings that all classify
// deferrable), so `clean` stays unforgeable by truncation (#270).
// computeAllDimensionsFailed — did this cycle produce NO review signal?
//
// True iff a review was OWED and nothing that was dispatched came back. The two
// clauses answer different questions and both are load-bearing:
//
//   somethingWasDue — the cycle owed a review. `dimensionsSkipped` is non-empty
//                     exactly when a dimension that should have run was dropped
//                     at the budget floor, INCLUDING build-time drops that never
//                     reach `reviewResults` at all.
//   every((r) => !r) — nothing dispatched reported. Vacuously true on an empty
//                     array, which is what makes the first clause necessary
//                     rather than a redundant guard.
//
// The empty-`dimensions` case splits on `somethingWasDue`, and that split is the
// whole point: narrowing legitimately selecting nothing (the delta touches no
// dimension's types, nothing prior-blocking) is a COMPLETE cycle that owed no
// review, while the budget floor skipping every candidate before dispatch leaves
// an identical empty array and IS a cycle that reviewed nothing it owed.
//
// Extracted here — before the orchestration body, like `computeClean` and for
// the same reason — because the orchestration body is untestable: nothing past
// ORCH_BOUNDARY can be pulled into a unit test, so a truth table written against
// it can only re-implement it, and a reimplementation drifts silently from the
// code it claims to pin. This predicate has been wrong five times (#616 review
// cycles 3-7: manifest-only, disjoint-population counts, the empty-array
// conflation, a missing emission, a hardcoded literal), so it is precisely the
// code that must be exercised directly rather than mirrored.
const computeAllDimensionsFailed = (reviewResults, dimensionsSkipped) =>
  (reviewResults.length > 0 || dimensionsSkipped.length > 0) && reviewResults.every((r) => !r)

// The dimensions whose job REQUIRES reading code (#1111). For these, an empty
// answer formed from the inline diff alone is not a review: security,
// correctness, and test coverage are all questions about code the diff hunks only
// partly show. The other dimensions are legitimately diff-only — `scope-drift`
// compares the diff against the issue, and `decomposition` judges the pre-scan's
// size numbers — so a diff-only answer from them IS engagement. Classifying them
// unengaged would fire every cycle, force a retry every cycle, and block
// convergence forever (operator correction on the #1111 plan).
//
// This list is the ONE source for that distinction. The caller-side transcript
// detector (scripts/review-engagement.sh) applies its zero-tool-call rule only
// where the cycle result's `dimension_engagement.<dim>.requires_code_reading` is
// true, which buildResult stamps from here — so the two detectors cannot drift
// into disagreeing about which dimensions may be diff-only.
const CODE_READING_DIMENSIONS = ['security', 'correctness', 'tests']

// classifyEngagement — did a dimension that RETURNED actually review anything?
//
// The success-side sibling of `computeAllDimensionsFailed` (#846 covers a
// dimension that dies; this covers one that succeeds having said nothing).
// Returns 'failed' | 'engaged' | 'unengaged':
//   - null result -> 'failed'. Kept distinct so the existing partial-cycle path
//     (budgetExhausted + dimensionsSkipped) owns it unchanged.
//   - any finding -> 'engaged'. A finding is evidence of looking by itself.
//   - empty findings AND empty `checked` -> 'unengaged', for EVERY dimension: the
//     answer names nothing it examined.
//   - empty findings, and every `checked` entry is `diff-only` -> 'unengaged'
//     ONLY for a CODE_READING_DIMENSIONS member; 'engaged' for the rest.
const classifyEngagement = (dimName, result) => {
  if (!result) return 'failed'
  const findings = Array.isArray(result.findings) ? result.findings : []
  const checked = Array.isArray(result.checked) ? result.checked : []
  if (findings.length > 0) return 'engaged'
  if (checked.length === 0) return 'unengaged'
  const diffOnly = checked.every((c) => c && c.how === 'diff-only')
  if (diffOnly && CODE_READING_DIMENSIONS.includes(dimName)) return 'unengaged'
  return 'engaged'
}

// The engagement floor's post-barrier bookkeeping (#1111), extracted here for
// the same reason as `computeAllDimensionsFailed` (#1128): the orchestration
// body only dispatches, and a retry merge or stamp written inline past
// ORCH_BOUNDARY could be pinned only by source greps — which kept passing with
// the replace line deleted or inverted.
//
// selectRetries — indices of dimensions that RETURNED but reviewed nothing, the
// only ones re-dispatched on opus. A null result is the failed path, not a
// retry candidate; an engaged one pays nothing.
const selectRetries = (dimensions, reviewResults) =>
  reviewResults.reduce((idx, res, i) => {
    if (res && classifyEngagement(dimensions[i].dim.name, res) === 'unengaged') idx.push(i)
    return idx
  }, [])

// mergeRetried — fold the opus retries back over the first-pass results.
// Returns `{ results, retrySucceeded }` and never mutates its input. A truthy
// retry REPLACES the original and records its index. A null retry — agent()
// returned null, or the thunk declined to spend below BUDGET_FLOOR — leaves the
// original (unengaged) result in place, so the dimension is still reported
// unengaged — never dropped to the null/failed path, which would lose the
// reason. `retrySucceeded` is distinct from `retryIdx` so "selected for a retry"
// is never reported as "re-run on opus" (PR #1127 cycle-5 review).
const mergeRetried = (reviewResults, retryIdx, retried) => {
  const results = reviewResults.slice()
  const retrySucceeded = []
  retryIdx.forEach((i, k) => {
    if (retried[k]) {
      results[i] = retried[k]
      retrySucceeded.push(i)
    }
  })
  return { results, retrySucceeded }
}

// stampEngagement — classify every dimension result once the retries are in.
// Returns `{ rawFindings, unengagedDimensions, dimensionEngagement, skippedAdds,
// partial }`:
//   - unengaged -> listed in BOTH `unengagedDimensions` (which says why) and
//     `skippedAdds` (appended to dimensionsSkipped), and the cycle is partial.
//   - null -> `skippedAdds` and partial. Its agent threw (runtime budget
//     exhausted mid-barrier, or any other terminal failure — parallel() nulls
//     both), OR the in-thunk ceiling check declined to spend. A finding the
//     judge never returned a verdict for must default to deferrable (filed,
//     never dropped) and `clean` is forced false (#270).
//   - engaged -> its findings join `rawFindings`, tagged with the dimension.
// `partial` is applied to the caller's local `budgetExhausted`, not only derived
// in buildResult: the judge prompt and applyJudgeVerdicts' default disposition
// both read that flag, and a partial cycle must default unjudged findings to
// deferrable on THIS path as well. `skippedAdds` keeps iteration order.
const stampEngagement = (dimensions, reviewResults, retryIdx, retrySucceeded) => {
  const rawFindings = []
  const unengagedDimensions = []
  const dimensionEngagement = {}
  const skippedAdds = []
  let partial = false
  reviewResults.forEach((res, i) => {
    const name = dimensions[i].dim.name
    const verdict = classifyEngagement(name, res)
    // Guarded like classifyEngagement: the dispatch `.then` always sets both
    // arrays today, but a result missing one must be counted, not thrown on.
    const checked = res && Array.isArray(res.checked) ? res.checked : []
    const findings = res && Array.isArray(res.findings) ? res.findings : []
    dimensionEngagement[name] = {
      engagement: verdict,
      checked: checked.length,
      // The dimension's RAW finding count, before the judge. review-engagement.sh
      // keys its "produced a finding" exemption off this rather than re-deriving
      // it from the post-judge blocking/deferrable arrays: that only works while
      // applyJudgeVerdicts never drops a finding (true today: it partitions every
      // raw finding), and stating the count here removes the dependence.
      findings: findings.length,
      retry_attempted: retryIdx.includes(i),
      retry_succeeded: retrySucceeded.includes(i),
      requires_code_reading: CODE_READING_DIMENSIONS.includes(name),
    }
    if (verdict === 'unengaged') {
      unengagedDimensions.push(name)
      skippedAdds.push(name)
      partial = true
      return
    }
    if (!res) {
      skippedAdds.push(name)
      partial = true
      return
    }
    for (const f of findings) rawFindings.push({ ...f, dimension: res.dim })
  })
  return { rawFindings, unengagedDimensions, dimensionEngagement, skippedAdds, partial }
}

const computeClean = (blockingLen, unresolvedLen, budgetExhausted) =>
  blockingLen === 0 && unresolvedLen === 0 && !budgetExhausted
