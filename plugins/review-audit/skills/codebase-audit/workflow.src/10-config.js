// --- SIZE DECISION (#718, following #503 AC3): STRUCTURABLE — applied via #806 -
//
// #503 AC3 asked for a per-harness structurable-vs-irreducible decision so this
// file's size row stops being re-filed. The answer for this harness is
// STRUCTURABLE, and #808 applied it — the fragment layout you are reading. The
// other two levers were measured, not estimated, and both are closed:
//
//   - TRIMMING PROMPT PROSE was measured and rejected. String literals were 178
//     of 877 non-comment lines (20%) and 12,557 of 31,268 non-comment chars
//     (40%) — a normal share for a fan-out harness, not accreted prose. The
//     decisive evidence is a time series on the sibling harness: ship-issue
//     measured the SAME 24%/44% at its 649-line revision as at its 1930-line
//     one, so these files grow proportionally in prompt and control flow
//     together. There is no prose surplus to reclaim.
//
//   - SHARED-LOGIC EXTRACTION across harnesses is real but blocked. A
//     6-line-window sweep across all six harnesses found 54 duplicated lines
//     here (4%) — `attempt`, `stableStringify`, the budget-degradation guard.
//     That is the known BUDGET_FLOOR class: the generated ARTIFACT still cannot
//     `import`, so a fragment cannot be shared ACROSS harnesses even though
//     #806 made fragments shareable WITHIN one. tests/lint-skills-agents.sh
//     gates the duplication instead.
//
// Note the build step is what made the split possible at all. Before #806 the
// only available lever here was the in-file entry-point + banner pattern
// (orchestrate/workflow.js is the reference shape, and code-reviewer/workflow.js
// still uses it). Do not read this decision as "any harness can be split" — an
// unenrolled harness still cannot, for the reason 00-meta.js's siblings and
// tests/lint-workflow-js-generated.sh both spell out.
// -----------------------------------------------------------------------------

// --- Config & input parsing --------------------------------------------------

const scope = args && typeof args.scope === 'string' ? args.scope : ''
const onlyCategories = args && Array.isArray(args.categories) ? args.categories.filter(Boolean) : null
const depth = args && ['quick', 'standard', 'deep'].includes(args.depth) ? args.depth : 'standard'
const severityThreshold =
  args && ['critical', 'high', 'medium', 'low'].includes(args.severityThreshold)
    ? args.severityThreshold
    : 'medium'
// Objective output: where the actionable findings go. Resolved by the SKILL
// layer (asked per run when omitted); the harness defensively coerces anything
// that is not the literal 'issues' to 'files' so an unset/garbled value never
// mutates a tracker unprompted.
const output = args && args.output === 'issues' ? 'issues' : 'files'
// Report summary is written unless explicitly disabled (default true).
const writeReport = !(args && args.writeReport === false)
// Run stamp for ./audit paths — the JS engine has no Date, so the SKILL layer
// computes it and passes it in. Sanitized (it lands in file paths) with a fixed
// fallback so paths stay well-formed even if it is missing.
const timestamp =
  args && typeof args.timestamp === 'string' && args.timestamp.trim()
    ? args.timestamp.trim().replace(/[^0-9A-Za-z:._-]/g, '')
    : 'audit'
// auditDir + the derived audit paths are computed AFTER the path-safety helpers
// (sanitizeDir) are defined below — see "Audit output paths".

