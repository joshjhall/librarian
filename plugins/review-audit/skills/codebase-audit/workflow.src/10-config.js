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

