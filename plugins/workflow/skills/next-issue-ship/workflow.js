export const meta = {
  name: 'next-issue-review',
  description:
    'Budgeted, resumable adversarial review for next-issue-ship: fans review dimensions (security/correctness/tests/conventions/scope-drift) as one parallel barrier under a single budget, folds in open PR review comments (post-PR cycles), re-scores with a fresh judge, then classifies each finding blocking-vs-deferrable for the skill to resolve-or-defer. One cycle per invocation — the skill owns the cycle loop and the cap.',
  phases: [
    { title: 'Manifest', detail: 'build + classify the changed-file manifest, decide specialists' },
    { title: 'Review', detail: 'review dimensions run as one parallel barrier under one budget' },
    { title: 'Comments', detail: 'fold open GitHub PR review comments into the finding stream (pr-cycle only)' },
    { title: 'Rescore', detail: 'fresh judge panel re-scores each finding certainty (no producer self-grading)' },
    { title: 'Classify', detail: 'split findings into blocking vs deferrable; emit the resolve-or-defer plan' },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     phase:      'pre-pr' | 'pr-cycle',   // default 'pre-pr'
//     cycle:      number,                  // 1-based; the skill increments. default 1
//     maxCycles:  number,                  // default 3 — informational; the SKILL enforces the cap
//     files?:     string[],                // changed-file scope (skill: git diff --name-only)
//     diff?:      string,                  // precomputed diff for context
//     prComments?: [{ id, author, path?, line?, body, url? }],  // pr-cycle only
//     issue?:     { number, title }        // for scope-drift + defer-issue context
//   }
//
// Returns (one cycle):
//   { cycle, phase, scanner, blocking[], deferrable[], comments_addressed[],
//     summary{...}, budget_exhausted, clean }
//   `clean === (blocking.length === 0)` is the per-cycle termination signal the
//   skill reads (combined by the skill with CI-green + comments-resolved).
//
// Nesting: this harness drives the code-reviewer agent via `agentType` (NOT
// `workflow()`), so the one allowed Workflow nesting level stays free and a
// single shared token budget spans every dimension. The cycle counter,
// resolve-or-defer, and re-review loop live in the SKILL + this script. A golem
// running the parent skill is an OS PROCESS, never itself a Workflow subagent —
// an orchestrator that spawned it as a Workflow subagent would consume the one
// nesting level and make this harness throw (see #524).
//
// The dimensions reuse the code-reviewer agent's discriminated modes (`manifest`,
// `reviewer:<name>`, `rescore`) for security + correctness; the NEW dimensions
// (tests, conventions, scope-drift) supply their instructions inline here so no
// edit to code-reviewer.md is needed (coordinate-free with #498). Every reviewer
// returns the identical FINDINGS_SCHEMA so rescore/classify work unchanged.
// Review is read-only: no agent edits, commits, or pushes — the skill applies
// fixes, commits, and files deferred findings.
// ---------------------------------------------------------------------------

const PHASE = args && args.phase === 'pr-cycle' ? 'pr-cycle' : 'pre-pr'
const CYCLE = args && Number.isInteger(args.cycle) ? args.cycle : 1
const MAX_CYCLES = args && Number.isInteger(args.maxCycles) ? args.maxCycles : 3
const scopeFiles = args && Array.isArray(args.files) ? args.files.filter(Boolean) : []
const scopeDiff = args && typeof args.diff === 'string' ? args.diff : ''
const prComments = args && Array.isArray(args.prComments) ? args.prComments.filter(Boolean) : []
const issue = args && args.issue && typeof args.issue === 'object' ? args.issue : null

// Dimensions that reuse the code-reviewer agent's own Sub-Reviewer Definitions.
// `security` keeps its category; `bug` is the agent's correctness reviewer but
// we surface it under category=correctness to match the issue's dimension name.
const REUSED_DIMENSIONS = [
  { name: 'security', mode: 'security', category: 'security' },
  { name: 'correctness', mode: 'bug', category: 'correctness' },
]

// NEW dimensions: no matching Sub-Reviewer Definition exists in code-reviewer.md,
// so the instructions are supplied inline (the direct analog of the agent's own
// Sub-Reviewer Definitions, which also live next to the harness).
const NEW_DIMENSIONS = [
  {
    name: 'tests',
    category: 'tests',
    instructions:
      'You are a test-coverage reviewer. Flag: changed source files with no ' +
      'corresponding test file; public/exported functions or methods not ' +
      'referenced by any test; happy-path-only coverage that omits error and ' +
      'edge cases; assertions that do not actually assert behavior (tautological ' +
      'or snapshot-only). Do not flag pure config/doc/template changes.',
  },
  {
    name: 'conventions',
    category: 'conventions',
    instructions:
      'You are a project-conventions reviewer. Read the repo-root CLAUDE.md and ' +
      'AGENTS.md, any directory-level CLAUDE.md covering the changed paths, and ' +
      '.claude/memory/*.md. Flag changes that violate documented project ' +
      'conventions: naming, file/module structure, banned patterns, required ' +
      'patterns (e.g. full command paths in scripts, --locked pinned versions, ' +
      'just-recipe usage, conventional-commit scopes). Cite the convention you ' +
      'are applying in the description. Skip generic style preferences not ' +
      'backed by a documented convention.',
  },
  {
    name: 'scope-drift',
    category: 'scope-drift',
    instructions:
      'You are a scope-drift reviewer. Compare the diff against the issue title ' +
      'and body below (Affected Files / Acceptance Criteria if present). Flag: ' +
      '(a) changes unrelated to the stated issue scope as deferrable-leaning ' +
      'out-of-scope work, and (b) acceptance criteria the diff does NOT yet ' +
      'satisfy as high-severity incompleteness. This mirrors the drift-detect ' +
      'skill but as advisory findings.' +
      (issue
        ? `\n\nIssue #${issue.number}: ${issue.title}`
        : '\n\n(No issue context provided — flag only obvious out-of-scope changes.)'),
  },
]

// Stop spawning further reviewers once the shared budget gets this close to
// empty, so a partial cycle still returns classified findings instead of
// throwing mid-barrier. Matches the ci-fixer / code-reviewer harnesses.
const BUDGET_FLOOR = 40_000

const CERTAINTY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['level', 'support', 'confidence', 'method'],
  properties: {
    level: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW'] },
    support: { type: 'integer' },
    confidence: { type: 'number' },
    method: { type: 'string' },
  },
}

const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'severity',
    'file',
    'line_start',
    'line_end',
    'category',
    'title',
    'description',
    'suggestion',
    'effort',
    'tags',
    'related_files',
    'certainty',
  ],
  properties: {
    severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
    file: { type: 'string' },
    line_start: { type: 'integer' },
    line_end: { type: 'integer' },
    category: { type: 'string' },
    title: { type: 'string' },
    description: { type: 'string' },
    suggestion: { type: 'string' },
    effort: { type: 'string', enum: ['trivial', 'small', 'medium', 'large'] },
    tags: { type: 'array', items: { type: 'string' } },
    related_files: { type: 'array', items: { type: 'string' } },
    certainty: CERTAINTY_SCHEMA,
  },
}

// Step 1-2 of the code-reviewer agent: changed-file manifest + per-file type
// classification + which conditional specialists are needed.
const MANIFEST_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['files', 'classifications', 'needs', 'diff'],
  properties: {
    files: { type: 'array', items: { type: 'string' } },
    classifications: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'types'],
        properties: {
          file: { type: 'string' },
          types: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    needs: {
      type: 'object',
      additionalProperties: false,
      required: ['database', 'devops'],
      properties: {
        database: { type: 'boolean' },
        devops: { type: 'boolean' },
      },
    },
    diff: { type: 'string' },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: FINDING_SCHEMA },
  },
}

// Fresh judge panel: re-scores certainty ONLY, keyed back to each finding by
// its unique `ref` (stamped before rescore). No new findings, no other fields.
const RESCORE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['scores'],
  properties: {
    scores: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['ref', 'certainty'],
        properties: {
          ref: { type: 'string' },
          certainty: {
            type: 'object',
            additionalProperties: false,
            required: ['level', 'confidence'],
            properties: {
              level: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW'] },
              confidence: { type: 'number' },
            },
          },
        },
      },
    },
  },
}

// Fold open PR review comments into the finding stream (pr-cycle only): each
// comment is triaged to a disposition so the skill can resolve-or-defer it.
const COMMENTS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['triaged'],
  properties: {
    triaged: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'disposition', 'note'],
        properties: {
          id: { type: 'string' },
          // already-addressed: the comment is resolved by the current diff.
          disposition: { type: 'string', enum: ['blocking', 'deferrable', 'already-addressed'] },
          note: { type: 'string' },
          // present when disposition=blocking|deferrable and the comment maps to
          // a concrete code finding the skill should act on.
          finding: FINDING_SCHEMA,
        },
      },
    },
  },
}

// Resolve-or-defer: one disposition per finding, keyed by ref.
const CLASSIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['decisions'],
  properties: {
    decisions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['ref', 'disposition', 'rationale'],
        properties: {
          ref: { type: 'string' },
          disposition: { type: 'string', enum: ['blocking', 'deferrable'] },
          rationale: { type: 'string' },
        },
      },
    },
  },
}

const READONLY =
  'This is a read-only review: do NOT edit, write, commit, branch, or push. ' +
  'Run at the code-reviewer agent model tier (sonnet).'

const scopeHeader = () => {
  const fileList = scopeFiles.length
    ? `Review scope (files): ${scopeFiles.join(', ')}\n`
    : 'No explicit file list provided — derive scope from `git diff --name-only origin/main...HEAD`.\n'
  const diffBlock = scopeDiff ? `\nProvided diff for context:\n${scopeDiff}\n` : ''
  return fileList + diffBlock
}

const manifestPrompt = () =>
  `Mode: manifest.\n${scopeHeader()}\n` +
  `Follow Steps 1-2 of your instructions: build the changed-file manifest, read each ` +
  `file for context, and classify every file's type(s). Decide which conditional ` +
  `specialists are needed: set needs.database=true if any file is type database, and ` +
  `needs.devops=true if any file is type ci or docker. Return the typed manifest ` +
  `(files, per-file classifications, needs, and the diff text). ` +
  READONLY

// Reused dimensions (security, correctness): defer to the agent's own
// Sub-Reviewer Definition, only overriding the surfaced category name.
const reusedReviewerPrompt = (dim, manifest) =>
  `Mode: reviewer:${dim.mode}.\n` +
  `Analyze the changed files below as the ${dim.mode} sub-reviewer using the ` +
  `corresponding Sub-Reviewer Definition in your instructions. Set ` +
  `category=${dim.category} on every finding and return the typed findings array ` +
  `(empty if none).\n\n` +
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Classifications: ${JSON.stringify(manifest.classifications)}\n\n` +
  `Diff:\n${manifest.diff}\n\n` +
  READONLY

// New dimensions (tests, conventions, scope-drift): instructions supplied inline.
const newReviewerPrompt = (dim, manifest) =>
  `Mode: reviewer:${dim.name} (custom dimension).\n` +
  `${dim.instructions}\n\n` +
  `Set category=${dim.category} on every finding and return the typed findings ` +
  `array (empty if none), using the same finding schema as your other reviews.\n\n` +
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Classifications: ${JSON.stringify(manifest.classifications)}\n\n` +
  `Diff:\n${manifest.diff}\n\n` +
  READONLY

const commentsPrompt = (manifest) =>
  `Mode: comment-triage (custom).\n` +
  `Below are open PR review comments. For EACH comment decide a disposition ` +
  `against the current diff:\n` +
  `- already-addressed: the current diff already resolves it (no action needed).\n` +
  `- blocking: it must be fixed on this PR before merge (correctness/security/` +
  `incompleteness, or an explicit reviewer change request).\n` +
  `- deferrable: a valid but non-blocking improvement to file as a follow-up issue.\n` +
  `When disposition is blocking or deferrable AND the comment maps to a concrete ` +
  `code location, attach a finding (full finding schema, category="review-comment"). ` +
  `Key each decision to the comment by its id.\n\n` +
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Diff:\n${manifest.diff}\n\n` +
  `Open PR review comments:\n${JSON.stringify(prComments)}\n\n` +
  READONLY

const rescorePrompt = (findings) =>
  `Mode: rescore. You are a FRESH judge panel — you did NOT produce these findings.\n` +
  `Independently re-score the certainty (level + confidence) of each finding below ` +
  `based solely on the evidence in its description and suggestion. Re-score certainty ` +
  `ONLY: do not add, remove, merge, or otherwise alter any finding. Key each score ` +
  `back to its finding by the \`ref\` field carried on that finding — copy it verbatim ` +
  `(it is a unique id; do not reconstruct it from other fields).\n\n` +
  `Findings to re-score:\n${JSON.stringify(findings)}\n\n` +
  READONLY

const classifyPrompt = (findings, budgetExhausted) =>
  `Mode: classify. You are a FRESH gatekeeper — you did NOT produce these findings.\n` +
  `Assign each finding a disposition for a single PR, applying this policy:\n` +
  `BLOCKING (must be fixed on this PR before the golem stops):\n` +
  `  - severity critical or high AND certainty.level is HIGH or MEDIUM\n` +
  `  - any security finding at HIGH certainty (any severity)\n` +
  `  - any scope-drift finding describing an UNADDRESSED acceptance criterion ` +
  `(the work is incomplete)\n` +
  `  - any tests finding of a missing test file for a changed source file at ` +
  `HIGH certainty\n` +
  `DEFERRABLE (file as a follow-up issue, do not block this PR):\n` +
  `  - severity medium or low, OR certainty.level LOW\n` +
  `  - scope-drift findings that are out-of-scope improvements (belong in their ` +
  `own issue)\n` +
  `  - performance/style-flavored suggestions not tied to a correctness or ` +
  `security risk\n` +
  `  - anything with effort=large (a large fix is its own issue), UNLESS ` +
  `severity is critical\n` +
  (budgetExhausted
    ? `NOTE: the budget was exhausted this cycle — bias any genuinely ambiguous ` +
      `finding to DEFERRABLE so it is filed, never silently dropped.\n`
    : '') +
  `Return exactly one decision per finding, keyed by the \`ref\` field carried on ` +
  `that finding — copy it verbatim (it is a unique id; do not reconstruct it).\n\n` +
  `Findings to classify:\n${JSON.stringify(findings)}\n\n` +
  READONLY

// A finding's stable, UNIQUE id. file:line_start:category alone collides when
// two findings share a file+line+category (e.g. two correctness findings on the
// same line), which would make rescore/classify silently overwrite one
// disposition with the other's. The trailing index disambiguates; it is stamped
// onto each finding (as `.ref`) before rescore/classify so the judge and
// gatekeeper key off the exact same id we read back.
const refOf = (f) => f.ref

function emptyResult(budgetExhausted, note) {
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
    },
    budget_exhausted: !!budgetExhausted,
    // No blocking findings produced — but a manifest/early failure is not a
    // clean signal, so callers pass clean explicitly where it matters. Default
    // to true only for the genuinely-empty case.
    clean: true,
  }
}

log(`review cycle ${CYCLE}/${MAX_CYCLES} (phase: ${PHASE})`)

// --- Manifest ---------------------------------------------------------------
phase('Manifest')

const manifest = await agent(manifestPrompt(), {
  label: 'manifest',
  phase: 'Manifest',
  agentType: 'code-reviewer',
  schema: MANIFEST_SCHEMA,
})

if (!manifest) {
  const r = emptyResult(false, 'manifest step failed — nothing to review this cycle')
  // A failed manifest is not a clean pass: do not let the skill stop the loop
  // on a degenerate cycle.
  r.clean = false
  return r
}

// --- Review (dimensions as ONE barrier under one budget) --------------------
phase('Review')

let budgetExhausted = false
const dimensions = []
// Reused dimensions first (cheap, always run), then new dimensions, then any
// conditional specialists the manifest asked for — each gated on the budget.
for (const d of REUSED_DIMENSIONS) dimensions.push({ kind: 'reused', dim: d })
for (const d of NEW_DIMENSIONS) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) {
    budgetExhausted = true
    log(`budget low — skipping dimension "${d.name}"`)
    continue
  }
  dimensions.push({ kind: 'new', dim: d })
}
// Conditional specialists from the manifest (reuse code-reviewer's own modes).
const conditional = []
if (manifest.needs.database) conditional.push({ name: 'database', mode: 'database', category: 'database' })
if (manifest.needs.devops) conditional.push({ name: 'devops', mode: 'devops', category: 'devops' })
for (const d of conditional) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) {
    budgetExhausted = true
    log(`budget low — skipping conditional specialist "${d.name}"`)
    continue
  }
  dimensions.push({ kind: 'reused', dim: d })
}

const reviewResults = await parallel(
  dimensions.map((entry) => () => {
    const prompt =
      entry.kind === 'new'
        ? newReviewerPrompt(entry.dim, manifest)
        : reusedReviewerPrompt(entry.dim, manifest)
    return agent(prompt, {
      label: `review:${entry.dim.name}`,
      phase: 'Review',
      agentType: 'code-reviewer',
      schema: FINDINGS_SCHEMA,
    }).then((r) => ({ dim: entry.dim.name, findings: (r && r.findings) || [] }))
  })
)

const rawFindings = []
reviewResults.forEach((res, i) => {
  if (!res) {
    // A null result means the dimension's agent threw. The most common cause
    // mid-barrier is the shared token budget running out (later agents in the
    // barrier throw once it is exhausted), but parallel() also nulls any other
    // terminal failure. Either way the cycle is now PARTIAL: mark it exhausted
    // so the classifier biases ambiguous findings to deferrable and the skill
    // does not treat a half-reviewed cycle as a clean pass.
    budgetExhausted = true
    log(`dimension "${dimensions[i].dim.name}" failed — continuing without its findings (cycle now partial)`)
    return
  }
  for (const f of res.findings) rawFindings.push({ ...f, dimension: res.dim })
})

// --- Comments (pr-cycle only: fold open PR review comments) -----------------
const commentsAddressed = []
if (PHASE === 'pr-cycle' && prComments.length) {
  phase('Comments')
  const triage = await agent(commentsPrompt(manifest), {
    label: 'comment-triage',
    phase: 'Comments',
    agentType: 'code-reviewer',
    schema: COMMENTS_SCHEMA,
  })
  if (triage) {
    for (const t of triage.triaged) {
      commentsAddressed.push({ id: t.id, disposition: t.disposition, note: t.note })
      // A blocking/deferrable comment with a concrete finding joins the stream
      // so it is rescored + classified like any other finding.
      if (t.finding && (t.disposition === 'blocking' || t.disposition === 'deferrable')) {
        rawFindings.push({ ...t.finding, dimension: 'review-comment', comment_id: t.id })
      }
    }
  } else {
    log('comment-triage failed — PR comments left unresolved for this cycle')
  }
}

// Unresolved comments (no disposition, or triage failed) keep the loop honest:
// the skill checks comments_addressed against the full comment set.
const unresolvedComments = prComments.length
  ? prComments.filter((c) => !commentsAddressed.some((a) => a.id === c.id))
  : []
if (unresolvedComments.length) {
  log(`${unresolvedComments.length} PR comment(s) not yet resolved-or-deferred`)
}

if (rawFindings.length === 0) {
  const r = emptyResult(budgetExhausted, 'no findings this cycle')
  r.comments_addressed = commentsAddressed
  // Clean only if every comment is resolved-or-deferred too.
  r.clean = unresolvedComments.length === 0
  return r
}

// Stamp a UNIQUE, stable ref onto every finding now that the full set is
// assembled (review dimensions + folded PR comments). The index guarantees
// uniqueness even when file+line+category collide, so rescore and classify can
// key dispositions back without one finding overwriting another's verdict.
rawFindings.forEach((f, i) => {
  f.ref = `${f.file}:${f.line_start}:${f.category}#${i}`
})

// --- Rescore (fresh judge panel; no producer self-grading) ------------------
phase('Rescore')

const rescored = await agent(rescorePrompt(rawFindings), {
  label: 'rescore',
  phase: 'Rescore',
  agentType: 'code-reviewer',
  schema: RESCORE_SCHEMA,
})

if (rescored) {
  const scoreByRef = new Map(rescored.scores.map((s) => [s.ref, s.certainty]))
  for (const f of rawFindings) {
    const next = scoreByRef.get(refOf(f))
    if (next) {
      f.certainty = { ...f.certainty, level: next.level, confidence: next.confidence }
    }
  }
} else {
  log('rescore step failed — keeping producer certainty as a fallback')
}

// --- Classify (fresh gatekeeper: blocking vs deferrable) --------------------
phase('Classify')

const classified = await agent(classifyPrompt(rawFindings, budgetExhausted), {
  label: 'classify',
  phase: 'Classify',
  agentType: 'code-reviewer',
  schema: CLASSIFY_SCHEMA,
})

// Default disposition if the classifier dropped a finding or failed entirely:
// when the budget was exhausted, defer (file it, never drop); otherwise treat
// an unclassified finding as blocking so it is not silently ignored.
const dispByRef = new Map(
  classified ? classified.decisions.map((d) => [d.ref, d.disposition]) : []
)
if (!classified) log('classify step failed — applying default dispositions')

const blocking = []
const deferrable = []
for (const f of rawFindings) {
  const disp = dispByRef.get(refOf(f)) || (budgetExhausted ? 'deferrable' : 'blocking')
  if (disp === 'deferrable') deferrable.push(f)
  else blocking.push(f)
}

const bySeverity = { critical: 0, high: 0, medium: 0, low: 0 }
for (const f of rawFindings) {
  if (bySeverity[f.severity] !== undefined) bySeverity[f.severity] += 1
}

return {
  cycle: CYCLE,
  phase: PHASE,
  scanner: 'next-issue-review',
  blocking,
  deferrable,
  comments_addressed: commentsAddressed,
  summary: {
    files_scanned: manifest.files.length,
    total_findings: rawFindings.length,
    by_disposition: { blocking: blocking.length, deferrable: deferrable.length },
    by_severity: bySeverity,
  },
  budget_exhausted: budgetExhausted,
  // A cycle is clean only when nothing blocks AND every PR comment is
  // resolved-or-deferred. The skill additionally requires CI-green.
  clean: blocking.length === 0 && unresolvedComments.length === 0,
}
