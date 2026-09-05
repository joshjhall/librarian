
// PR comment ids arrive numeric from `gh pr view --json reviews,comments`, but
// COMMENTS_SCHEMA coerces each triaged id to a string. Compare as strings so
// neither side's type wins — a strict `===` between a number and a string never
// matches, which would make every comment read as unresolved forever (clean
// unreachable) or, if the caller stringifies, hide an omitted triage row (#261).
const sameCommentId = (a, b) => String(a) === String(b)

// --- Re-review narrowing (#492) --------------------------------------------
// Extracted before the orchestration body (like computeClean / applyJudgeVerdicts)
// so the narrowing decision is pure and unit-testable in
// tests/validate-workflow-helpers.mjs without executing the harness.

// Narrowing is active only on a re-review cycle for which the caller actually
// supplied a fix-commit delta. Cycle 1 (the initial review) and any caller that
// omits the delta inputs fall back to the pre-#492 full review — the delta args
// are additive and default-off. Passed `cycle` + `deltaFiles` explicitly (not the
// module globals) so the predicate is testable in isolation.
const narrowingActive = (cycle, deltaDiff, deltaFiles) =>
  cycle > 1 && typeof deltaDiff === 'string' && deltaDiff.length > 0 && deltaFiles.length > 0

// Which of the manifest file types a delta-local dimension reviews. A dimension
// is "relevant to the delta" when the delta's classified types intersect this
// set — used on a narrowed cycle to decide whether a dimension that did NOT block
// last cycle still needs to re-run because the fix touched files it cares about
// (AC#3: a fix that introduces a fresh security/test/etc. issue is still caught).
// Keys are dimension NAMES (security, correctness, tests). The
// conditional specialists (database, devops) are gated by manifest.needs (whether
// the delta still classifies a file of their type) rather than by this type table,
// but they ALSO honor the prior-blocking carry-over via `includeSpecialist` below
// — a specialist that blocked last cycle re-runs even when the fix touched no file
// of its type (AC#3).
// NO ENTRY CURRENTLY USES THE '*' WILDCARD. `conventions` was its only user and
// was demoted from the fan-out (#551, see 30-dimensions.js). The wildcard branch
// in `dimensionTouchesDelta` is deliberately KEPT rather than deleted with it: it
// is a general mechanism of the table, not a fact about that one dimension, and a
// future all-types dimension should not have to re-derive it. It is currently
// unreachable from this table — a test can only reach it through a synthetic
// entry, which is what tests/workflow-helpers/ship-issue/03-narrowing-selector.mjs
// does.
// `config` is in security/correctness because a fix delta that touches only a
// config file (`.json`/`.yaml`/`.env*`) can still introduce a hardcoded secret or
// a config-driven logic bug — so those dimensions must re-run on a config-only
// delta, not be narrowed away (pre-PR review coverage-gap finding).
// `ci`/`docker` are in security/correctness for the same reason, and NOT because
// the `devops` specialist is absent — it still runs (gated on manifest.needs, see
// above), the two are complementary rather than redundant. Its checklist is
// infrastructure-shaped (root containers, exposed ports, secret-in-ENV, pinned
// images, health checks, resource limits) and carries neither the generic OWASP
// lens (command injection via unsanitized `RUN`/`ARG`, curl-pipe-to-shell, path
// traversal, credential handling inside CI shell scripts) nor any correctness
// lens at all — so without these entries a docker/CI-only fix delta (a bare
// `Dockerfile`, `docker-compose.yml`, `Jenkinsfile`, a workflow file) would drop
// both generic dimensions unless one of them blocked the previous cycle (#529).
// `tests` is deliberately NOT widened: a ci/docker-only delta needs no
// test-coverage lens.
// `decomposition` (#695) is delta-local and sizes anything with a segmenter:
// source, test and docs files all have production-LOC rules and a language-shaped
// split guidance arm. It is deliberately NARROWER than security/correctness —
// `config`/`ci`/`docker` are excluded because a JSON/YAML/Dockerfile is not a
// decomposition candidate (the scanner skips those extensions outright), so
// including them would re-run the dimension on deltas it can say nothing about.
// `docs` is INCLUDED and is the entry that matters most here: prose is this
// repo's largest and fastest-churning surface (#589), and the markdown
// progressive-disclosure case is the one the dimension is least redundant on.
const DIMENSION_RELEVANT_TYPES = {
  security: ['source', 'database', 'config', 'ci', 'docker'],
  correctness: ['source', 'database', 'config', 'ci', 'docker'],
  tests: ['source', 'test'],
  decomposition: ['source', 'test', 'docs'],
}

// True when the delta's classified file types intersect the dimension's relevant
// set (or the dimension matches all types via '*'). `deltaTypes` is the flat set
// of types the manifest assigned across the delta's files.
const dimensionTouchesDelta = (dimName, deltaTypes) => {
  const relevant = DIMENSION_RELEVANT_TYPES[dimName]
  if (!relevant) return false
  if (relevant.includes('*')) return true
  return relevant.some((t) => deltaTypes.has(t))
}

// Whether a conditional specialist (database, devops) runs this cycle. On a full
// cycle (or a non-narrowed re-review) it is gated purely by manifest.needs, as
// before. On a narrowed cycle it ALSO re-runs when it blocked last cycle — the
// specialist analog of `includeDeltaLocal`'s prior-blocking carry-over — so a
// database/devops finding whose fix touches no file of its type (leaving
// manifest.needs false on the delta-built manifest) is still re-verified (AC#3;
// closes the specialist gap the pre-PR review flagged). `narrowed` gates the
// carry-over so a full cycle is byte-identical to before.
const includeSpecialist = (specialistName, manifestNeeds, priorBlockingSet, narrowed) =>
  !!manifestNeeds || (narrowed && priorBlockingSet.has(specialistName))

// The diff an INCLUDED dimension/specialist reads on a (possibly narrowed) cycle.
// Full cycle ⇒ full diff (unchanged). Narrowed cycle:
//   - included because the fix delta TOUCHES its file types → the small delta diff
//     (the #492 saving: a fresh issue the fix introduced lives in the delta), UNLESS
//   - included via the PRIOR-BLOCKING carry-over → the FULL diff. The finding it must
//     re-confirm may live OUTSIDE the fix delta (the fix touched other files), so
//     handing it only the delta would blind it and let the still-unresolved finding
//     silently vanish from `blocking` — a false `clean` and a merge-safety hole (the
//     pre-#492 code re-ran every dimension against the full diff every cycle; this
//     preserves that safety net for exactly the re-confirm case). A dimension that is
//     BOTH prior-blocking and touched reads the full diff too — re-confirmation wins.
// scope-drift passes fullDiff via its own always-full path; this helper is for the
// delta-local dimensions and the specialists.
const diffForInclusion = (narrowed, touches, prior, fullDiff, deltaDiff) =>
  narrowed && touches && !prior ? deltaDiff : fullDiff

// Flatten the manifest classifications into the set of file types present in the
// (narrowed) scope. On a narrowed cycle the manifest was built over the delta, so
// this is exactly the delta's types.
const manifestTypeSet = (manifest) => {
  const types = new Set()
  for (const c of (manifest && manifest.classifications) || []) {
    for (const t of c.types || []) types.add(t)
  }
  return types
}

// Decide the ordered dimension entries for this cycle and the diff each one
// reads. Returns `{ entries, budgetExhausted, dimensionsSkipped }`:
//   - entries: [{ kind: 'reused'|'new', dim, diff }] for the parallel() barrier.
//   - budgetExhausted / dimensionsSkipped: threaded through unchanged — the
//     budget-floor skip of a NEW dimension or conditional specialist is a GENUINE
//     partial-cycle signal and still flips them. Narrowing (dropping a dimension
//     because the delta doesn't touch it and it didn't block) is NOT a partial
//     cycle and touches neither.
// Full cycle: exactly today's set (reused, then budget-gated new, then budget-gated
// specialists), every entry reading `fullDiff`. Narrowed cycle: each delta-local
// dimension is included only if it blocked last cycle OR the delta touches a type
// it reviews, reading `deltaDiff`; scope-drift is ALWAYS included reading `fullDiff`
// (whole-change lens); specialists stay gated on manifest.needs (built over the
// delta) exactly as on a full cycle.
const selectReviewDimensions = ({
  cycle,
  fullDiff,
  deltaDiff,
  deltaFiles,
  priorBlocking,
  manifest,
  budget,
  budgetFloor,
  reusedDimensions,
  newDimensions,
  route,
}) => {
  const narrowed = narrowingActive(cycle, deltaDiff, deltaFiles)
  // Doc-only routing (#550). `cheap` drops the dimensions that have nothing to
  // read in a diff containing no source, config, or unknown file.
  //
  // ROUTING IS NOT NARROWING AND NOT TRUNCATION, and the difference is what
  // keeps `clean` honest. A budget-skipped dimension SHOULD have run and did
  // not — a partial cycle, which can never read clean. A routed-around
  // dimension had nothing to read. So this path adds NOTHING to
  // `dimensionsSkipped` and never sets `budgetExhausted`, exactly as narrowing
  // already behaves.
  //
  // WHICH DIMENSIONS SURVIVE is derived from DIMENSION_RELEVANT_TYPES above,
  // not hardcoded: a dimension runs on a cheap cycle iff its entry claims the
  // `docs` type. That is the whole lesson of this feature's review history —
  // five separate blocking findings, every one a place where a hand-maintained
  // list disagreed with that table. Deriving removes the class.
  const cheap = route === 'cheap'
  const entries = []
  const dimensionsSkipped = []
  let budgetExhausted = false

  const priorSet = new Set(priorBlocking || [])
  const deltaTypes = narrowed ? manifestTypeSet(manifest) : null
  // On a narrowed cycle, a delta-local dimension runs iff it blocked last cycle or
  // the delta touches a type it reviews; on a full cycle every dimension runs. The
  // two reasons are tracked separately because they select DIFFERENT diffs (see
  // diffForInclusion): a touched-only inclusion reads the delta (the saving), a
  // prior-blocking inclusion reads the FULL diff (re-confirm a finding that may
  // live outside the delta).
  const touchesFor = (dimName) => narrowed && dimensionTouchesDelta(dimName, deltaTypes)
  const priorFor = (dimName) => narrowed && priorSet.has(dimName)
  // On a cheap (doc-only) cycle a dimension runs iff its normative entry claims
  // the `docs` type — DERIVED from DIMENSION_RELEVANT_TYPES, never a second
  // hardcoded list. `dimensionTouchesDelta` already implements exactly this
  // lookup (including the '*' wildcard, should one return), so reusing it means
  // the two can never disagree. Post-#551 the default set is five dimensions
  // and `decomposition` is the only one whose entry lists `docs`, so a cheap
  // cycle runs decomposition + scope-drift.
  const survivesCheapRoute = (dimName) => dimensionTouchesDelta(dimName, new Set(['docs']))
  const includeDeltaLocal = (dimName) =>
    cheap
      ? survivesCheapRoute(dimName)
      : !narrowed || priorFor(dimName) || touchesFor(dimName)

  // Reused dimensions (security, correctness) — cheap, no budget gate, but on a
  // narrowed cycle still subject to the include test.
  for (const d of reusedDimensions) {
    if (!includeDeltaLocal(d.name)) continue
    entries.push({
      kind: 'reused',
      dim: d,
      diff: diffForInclusion(narrowed, touchesFor(d.name), priorFor(d.name), fullDiff, deltaDiff),
    })
  }

  // NEW dimensions (tests, decomposition, scope-drift). scope-drift is a
  // whole-change lens: always included, always reading the FULL diff, never
  // narrowing-skipped. The others are delta-local (include test + per-inclusion
  // diff). Budget-floor gating is preserved for every new dimension that WOULD run.
  for (const d of newDimensions) {
    const isScopeDrift = d.name === 'scope-drift'
    if (!isScopeDrift && !includeDeltaLocal(d.name)) continue
    if (budget.total && budget.remaining() < budgetFloor) {
      budgetExhausted = true
      dimensionsSkipped.push(d.name)
      continue
    }
    const diff = isScopeDrift
      ? fullDiff
      : diffForInclusion(narrowed, touchesFor(d.name), priorFor(d.name), fullDiff, deltaDiff)
    entries.push({ kind: 'new', dim: d, diff })
  }

  return { entries, budgetExhausted, dimensionsSkipped, narrowed, cheap }
}

// `dimensionsRun` is passed in rather than read from the module-scope
// `dimensions`: this function is hoisted and the manifest-failure call site
// below runs BEFORE that const is initialized, so touching it here would throw
// a TDZ error on exactly the failure path that must degrade gracefully.
// `noReviewSignal` marks the cycle as having produced NO review signal at all —
// it died before any dimension ran, so it is not evidence about convergence in
// either direction. The convergence helper reads this field to decline charging
// the cycle against REVIEW_MAX_CYCLES (rule C0b), because otherwise three infra
// flakes exhaust the cap and dead-end the PR with a summary implying findings
// that were never produced (#616).
//
// It is an EXPLICIT parameter rather than something inferred from
// `dimensions_run === 0`: a narrowed cycle whose dimensions were all filtered
// out (#492) ran to completion by design, and inferring would conflate
// "reviewed nothing because nothing changed" with "reviewed nothing because it
// crashed". It defaults to false so every existing call site — all of which
// describe cycles that DID review — keeps its current meaning.
function emptyResult(budgetExhausted, note, dimensionsSkipped, dimensionsRun, noReviewSignal) {
  if (note) log(note)
  return {
    cycle: CYCLE,
    phase: PHASE,
    scanner: 'next-issue-review',
    blocking: [],
    deferrable: [],
    comments_addressed: [],
    summary: {
      files_scanned: scopeFiles.length,
      total_findings: 0,
      by_disposition: { blocking: 0, deferrable: 0 },
      by_severity: { critical: 0, high: 0, medium: 0, low: 0 },
      // Zeroed, not omitted, for the same reason token_report is reported here
      // (#553): a cycle absent from the sample biases it. A zero-finding cycle
      // is a real data point for the #613 tally — dropping the keys would make
      // it indistinguishable from a cycle that was never measured.
      by_nature: tallyBy([], NATURE_VALUES),
      by_rule: tallyBy([], DISPOSITION_RULES),
    },
    // Cost report on the empty/early paths too — a cycle that produced no
    // findings still spent tokens, and excluding it would bias the sample the
    // operator sizes a ceiling from (#553).
    token_report: {
      output_tokens: reviewBudget.spent(),
      ceiling: CYCLE_TOKEN_CEILING || null,
      bound: budget.total ? 'runtime' : CYCLE_TOKEN_CEILING ? 'caller' : 'none',
      dimensions_run: dimensionsRun || 0,
    },
    budget_exhausted: !!budgetExhausted,
    dimensions_skipped: dimensionsSkipped || [],
    // Always present (never conditionally omitted): the helper's default for an
    // absent field is `false`, so omitting it on the crash path and emitting it
    // elsewhere would make the two indistinguishable from outside.
    no_review_signal: !!noReviewSignal,
    // No blocking findings produced — but a budget-truncated cycle is PARTIAL
    // (some dimension never ran), so it can never read as clean; nor can a
    // manifest/early failure, for which callers still override clean explicitly.
    // Default to clean only when the cycle was genuinely complete and empty.
    clean: !budgetExhausted,
  }
}
