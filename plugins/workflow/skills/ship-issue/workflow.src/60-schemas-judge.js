
// Single fresh-judge pass: for each finding (keyed by its unique `ref`, stamped
// before the judge runs) return BOTH an independently re-scored certainty AND
// the finding's `nature` — an OBSERVATION about the finding, not a decision
// about what stops the ship. This merges what were two separate `fable`
// tail agents — rescore + classify — into one, halving the fable tail cost per
// cycle (#491). The judge still did NOT produce the findings, so the
// no-producer-self-grading property is preserved.
//
// Why `nature` and not `disposition` (#580): the judge used to return the
// blocking-vs-deferrable verdict directly, applying a prose policy. That policy
// was unsatisfiable in practice — across the #567 measurement batch (26 cycles,
// 67 findings) `blocking` fired ONCE, because BLOCKING required
// `severity ∈ {critical, high}` while DEFERRABLE fired on `severity ∈ {medium,
// low}` OR `certainty == LOW`, and producers essentially never emit
// critical/high. The medium band was swallowed whole by the deferrable OR. Six
// cycles running returned `blocking: []` over a deferrable bucket holding a
// confirmed defect in code that PR had just written.
//
// So the judge now reports what it OBSERVES and `dispositionOf` (below) decides.
// An LLM applying prose cannot be unit-tested; an ordered rule list can, which
// is what makes #580's calibration gate possible at all.
//
// Independence tradeoff (deliberate): the two passes were both "fresh judge"
// gates, not a defense-in-depth pair — classify already READ rescore's certainty,
// so they never independently cross-checked each other. Merging them means one
// judge call now decides both certainty and disposition over the same
// `dataBlock`-fenced (untrusted) finding text. That fence + `sanitize` remain the
// injection control; the cost win is the point of #491, not a security
// regression. If a future change needs strict independent-gate redundancy for
// security-category findings, split THOSE back out — do not silently re-merge.
const JUDGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['ref', 'certainty', 'nature', 'rationale'],
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
          // An observation about the finding, NOT a merge decision — see
          // dispositionOf, which maps (nature x certainty x severity x effort)
          // to blocking/deferrable deterministically (#580).
          nature: { type: 'string', enum: NATURE_VALUES },
          rationale: { type: 'string' },
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
