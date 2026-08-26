
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
// classification + which conditional specialists are needed. The manifest
// deliberately does NOT carry the diff: transcribing it back through
// StructuredOutput cost ~diff-size output tokens per cycle (paid once per
// reviewer) and risked silent truncation/normalization (#267). Reviewers read
// the caller's byte-faithful diff via diffSection() instead.
const MANIFEST_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['files', 'classifications', 'needs'],
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
