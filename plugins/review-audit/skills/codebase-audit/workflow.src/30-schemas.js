// --- Schemas (inline; additionalProperties:false, explicit required) ---------

// The full finding-schema.md finding object, as a scanner emits it. The harness
// stamps a `.ref` onto each AFTER receipt (in JS), so `ref` is NOT a property
// here — the scanner never produces it.
const CERTAINTY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['level', 'support', 'confidence', 'method'],
  properties: {
    level: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
    support: { type: 'integer' },
    confidence: { type: 'number' },
    method: { type: 'string', enum: ['deterministic', 'heuristic', 'llm'] },
  },
}

const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'id',
    'category',
    'severity',
    'title',
    'description',
    'file',
    'line_start',
    'line_end',
    'evidence',
    'suggestion',
    'effort',
    'tags',
    'related_files',
    'certainty',
  ],
  properties: {
    id: { type: 'string' },
    category: { type: 'string' },
    severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
    title: { type: 'string' },
    description: { type: 'string' },
    file: { type: 'string' },
    line_start: { type: 'integer' },
    line_end: { type: 'integer' },
    evidence: { type: 'string' },
    suggestion: { type: 'string' },
    effort: { type: 'string', enum: ['trivial', 'small', 'medium', 'large'] },
    tags: { type: 'array', items: { type: 'string' } },
    related_files: { type: 'array', items: { type: 'string' } },
    certainty: CERTAINTY_SCHEMA,
    // Optional provenance carried by the checker; not required.
    pre_scan: { type: 'boolean' },
    skill: { type: 'string' },
  },
}

// Map: scope partition + skill/agent discovery + per-domain manifests.
const MAP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['platform', 'context', 'excluded', 'domains'],
  properties: {
    platform: { type: 'string', enum: ['github', 'gitlab', 'none'] },
    context: {
      type: 'object',
      additionalProperties: false,
      required: ['languages'],
      properties: {
        languages: { type: 'array', items: { type: 'string' } },
        framework: { type: 'string' },
        project_name: { type: 'string' },
      },
    },
    // Submodule / vendored / untracked-.env paths removed from every manifest,
    // surfaced so the user sees what was skipped.
    excluded: { type: 'array', items: { type: 'string' } },
    domains: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'scanner', 'source', 'files'],
        properties: {
          // The audit domain / category surfaced on findings + labels.
          name: { type: 'string' },
          // The check-* skill, audit-* agent, or project agent that drives it.
          scanner: { type: 'string' },
          source: { type: 'string', enum: ['check-skill', 'audit-agent', 'project'] },
          files: { type: 'array', items: { type: 'string' } },
          routing_hint: { type: 'string' },
        },
      },
    },
  },
}

// Scan: one domain's finding-schema.md output. acknowledged_findings is passed
// through to the report verbatim, so it is left unconstrained (array of any).
const SCAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['scanner', 'findings'],
  properties: {
    scanner: { type: 'string' },
    findings: { type: 'array', items: FINDING_SCHEMA },
    acknowledged_findings: { type: 'array' },
    files_scanned: { type: 'integer' },
  },
}

// Verify: a fresh checker re-scores certainty AND confirms reality, keyed back
// to each finding by the unique `ref` the harness stamped (copied verbatim).
const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['scores'],
  properties: {
    scores: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['ref', 'is_real', 'certainty'],
        properties: {
          ref: { type: 'string' },
          // false = the fresh judge refutes the finding; it is dropped.
          is_real: { type: 'boolean' },
          certainty: {
            type: 'object',
            additionalProperties: false,
            required: ['level', 'confidence'],
            properties: {
              level: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
              confidence: { type: 'number' },
            },
          },
          rationale: { type: 'string' },
        },
      },
    },
  },
}

// Aggregate: dedup + correlation + grouping. Groups reference findings by `ref`
// (not echoed verbatim) so the harness maps them back to the full objects it
// already holds — no lossy re-serialization by the model.
const AGGREGATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['groups', 'totals', 'report_markdown'],
  properties: {
    groups: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'category', 'scanner', 'severity', 'effort', 'labels', 'create_label', 'finding_refs'],
        properties: {
          title: { type: 'string' },
          category: { type: 'string' },
          scanner: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          effort: { type: 'string', enum: ['trivial', 'small', 'medium', 'large'] },
          labels: { type: 'array', items: { type: 'string' } },
          create_label: { type: 'boolean' },
          finding_refs: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    totals: {
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
    // The report summary (issue-templates.md § Report Summary Format), always
    // produced so it can be persisted to ./audit/{ts}-audit-report.md, returned
    // to the caller, and logged as a summary regardless of objective.
    report_markdown: { type: 'string' },
  },
}

// One issue-writer outcome.
const ISSUE_WRITER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['action', 'url', 'title', 'reason'],
  properties: {
    action: { type: 'string', enum: ['created', 'skipped', 'error'] },
    url: { type: 'string' },
    title: { type: 'string' },
    reason: { type: 'string' },
  },
}

// The artifact-writer outcome (the file-output counterpart to issue-writer):
// one dispatch writes ./audit/{ts}/findings.json + per-group md + the report.
const ARTIFACT_WRITER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['action', 'out_dir', 'files_written', 'report_path', 'reason'],
  properties: {
    action: { type: 'string', enum: ['written', 'error'] },
    out_dir: { type: 'string' },
    files_written: { type: 'array', items: { type: 'string' } },
    report_path: { type: 'string' },
    reason: { type: 'string' },
  },
}

