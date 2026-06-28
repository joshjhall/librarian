export const meta = {
  name: 'code-review',
  description:
    'Budgeted, resumable code review: a manifest step fans the core 4 + conditional specialists as one parallel barrier, a fresh judge panel re-scores certainty (no producer self-grading), then a merge step emits the finding-schema object.',
  phases: [
    { title: 'Manifest', detail: 'build + classify the changed-file manifest, decide specialists' },
    { title: 'Review', detail: 'core 4 + conditional specialists run as one parallel barrier' },
    { title: 'Rescore', detail: 'fresh judge panel re-scores each finding certainty' },
    { title: 'Merge', detail: 'acknowledge scan, dedup, correlate, emit finding-schema object' },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     files?: string[],   // explicit review scope; manifest step derives it if absent
//     diff?:  string       // pre-computed diff for context; derived if absent
//   }
//
// Returns the merge step's object: the `finding-schema.md` top-level structure
//   { scanner, summary, findings, acknowledged_findings }
//
// The fan-out, the shared token budget, and per-step resume all live HERE in
// the harness — NOT in the code-reviewer agent. The agent is one
// `agentType: "code-reviewer"` driven in four discriminated modes named in the
// prompt: `manifest`, `reviewer:<name>`, `rescore`, `merge`. Independent
// sub-reviewers fan with parallel() and share one budget; a sub-reviewer that
// throws drops to null and is filtered — the rest proceed. Per-step resume is
// automatic via the Workflow tool's journal (relaunch with resumeFromRunId).
// Review is read-only: no agent edits, commits, or pushes.
// ---------------------------------------------------------------------------

const scopeFiles = args && Array.isArray(args.files) ? args.files.filter(Boolean) : []
const scopeDiff = args && typeof args.diff === 'string' ? args.diff : ''

const CORE_REVIEWERS = ['security', 'bug', 'performance', 'style']

// Stop spawning conditional specialists once the shared budget gets this close
// to empty, so a partial review still returns merged findings instead of
// throwing mid-barrier.
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

// Step 1-2 of the agent: changed-file manifest + per-file type classification +
// which conditional specialists are needed.
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

// Step 7 of the agent: the finding-schema.md top-level object, unchanged.
const MERGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['scanner', 'summary', 'findings', 'acknowledged_findings'],
  properties: {
    scanner: { type: 'string' },
    summary: {
      type: 'object',
      additionalProperties: false,
      required: ['files_scanned', 'total_findings', 'by_severity'],
      properties: {
        files_scanned: { type: 'integer' },
        total_findings: { type: 'integer' },
        by_severity: {
          type: 'object',
          additionalProperties: false,
          required: ['critical', 'high', 'medium', 'low'],
          properties: {
            critical: { type: 'integer' },
            high: { type: 'integer' },
            medium: { type: 'integer' },
            low: { type: 'integer' },
          },
        },
      },
    },
    findings: { type: 'array', items: { type: 'object' } },
    acknowledged_findings: { type: 'array', items: { type: 'object' } },
  },
}

const READONLY =
  'This is a read-only review: do NOT edit, write, commit, branch, or push. ' +
  'Run at the code-reviewer agent model tier (sonnet).'

const scopeHeader = () => {
  const fileList = scopeFiles.length
    ? `Review scope (files): ${scopeFiles.join(', ')}\n`
    : 'No explicit file list provided — derive scope from `git diff --name-only` (staged + unstaged).\n'
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

const reviewerPrompt = (reviewer, manifest) =>
  `Mode: reviewer:${reviewer}.\n` +
  `Analyze the changed files below as the ${reviewer} sub-reviewer using the ` +
  `corresponding Sub-Reviewer Definition in your instructions. Set category=${reviewer} ` +
  `on every finding and return the typed findings array (empty if none).\n\n` +
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Classifications: ${JSON.stringify(manifest.classifications)}\n\n` +
  `Diff:\n${manifest.diff}\n\n` +
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

const mergePrompt = (findings, manifest, didRescore) =>
  `Mode: merge.\n` +
  (didRescore
    ? `Follow Steps 5-7 of your instructions on the findings below (certainty already ` +
      `re-scored by the judge panel — keep those values): `
    : `Follow Steps 5-7 of your instructions on the findings below (NOTE: the rescore ` +
      `step did not run — the certainty values are the producers' own; keep them as-is, ` +
      `do not re-grade): `) +
  `scan the changed files for ` +
  `audit:acknowledge comments and apply the suppression map, perform within-reviewer ` +
  `dedup and cross-reviewer correlation, re-sequence code-reviewer-<NNN> ids, sort, and ` +
  `recompute summary counts. Emit the finding-schema.md top-level object unchanged ` +
  `(scanner=code-reviewer, summary, findings, acknowledged_findings). ` +
  `INTEGRITY: every input finding must end up in EXACTLY ONE of findings (kept, ` +
  `possibly merged via dedup) or acknowledged_findings (suppressed) — never ` +
  `silently dropped. Set summary.total_findings = findings.length and recompute ` +
  `by_severity from the final findings array. ` +
  `files_scanned = ${manifest.files.length}.\n\n` +
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Findings:\n${JSON.stringify(findings)}\n\n` +
  READONLY

// A finding's stable, UNIQUE id. file:line_start:category alone collides when
// two findings share that triple (e.g. two bug-category findings on the same
// line), which would make the rescore keying silently overwrite one finding's
// certainty with the other's. The trailing index disambiguates; it is stamped
// onto each finding (as `.ref`) before rescore so the judge keys off the exact
// same id we read back.
const refOf = (f) => f.ref

function emptyReport(manifest) {
  return {
    scanner: 'code-reviewer',
    summary: {
      files_scanned: manifest ? manifest.files.length : 0,
      total_findings: 0,
      by_severity: { critical: 0, high: 0, medium: 0, low: 0 },
    },
    findings: [],
    acknowledged_findings: [],
  }
}

// --- Manifest ---------------------------------------------------------------
phase('Manifest')

const manifest = await agent(manifestPrompt(), {
  label: 'manifest',
  phase: 'Manifest',
  agentType: 'code-reviewer',
  schema: MANIFEST_SCHEMA,
})

if (!manifest) {
  log('manifest step failed — nothing to review')
  return emptyReport(null)
}

// --- Review (core 4 + conditional specialists as ONE barrier) ---------------
phase('Review')

const specialists = []
if (manifest.needs.database) specialists.push('database')
if (manifest.needs.devops) specialists.push('devops')

const reviewers = [...CORE_REVIEWERS]
for (const s of specialists) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) {
    log(`budget low — skipping conditional specialist "${s}"`)
    continue
  }
  reviewers.push(s)
}

const reviewResults = await parallel(
  reviewers.map((reviewer) => () =>
    agent(reviewerPrompt(reviewer, manifest), {
      label: `review:${reviewer}`,
      phase: 'Review',
      agentType: 'code-reviewer',
      schema: FINDINGS_SCHEMA,
    }).then((r) => ({ reviewer, findings: (r && r.findings) || [] }))
  )
)

// A sub-reviewer that threw resolves to null — log it and proceed with the rest.
const rawFindings = []
reviewResults.forEach((res, i) => {
  if (!res) {
    log(`sub-reviewer "${reviewers[i]}" failed — continuing without its findings`)
    return
  }
  for (const f of res.findings) rawFindings.push({ ...f, reviewer: res.reviewer })
})

if (rawFindings.length === 0) {
  log('no findings across all reviewers — changes look clean')
  return emptyReport(manifest)
}

// Stamp a UNIQUE, stable ref onto every finding now that the full set is
// assembled across all reviewers. The index guarantees uniqueness even when
// file+line+category collide, so the rescore can key certainty back without one
// finding overwriting another's score.
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

const didRescore = !!rescored
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

// --- Merge (acknowledge scan, dedup, correlate, emit finding-schema) --------
phase('Merge')

const report = await agent(mergePrompt(rawFindings, manifest, didRescore), {
  label: 'merge',
  phase: 'Merge',
  agentType: 'code-reviewer',
  schema: MERGE_SCHEMA,
})

return report || emptyReport(manifest)
