// --- Audit output paths (need sanitizeDir above) -----------------------------
// Sanitized root for file artifacts. `timestamp` is already stripped above.
const auditDir = sanitizeDir(args && typeof args.auditDir === 'string' ? args.auditDir : './audit')
// The report summary md always lives at the auditDir root (a sibling of the
// timestamped subdir) so it is easy to find across runs; '' disables it. The
// timestamped subdir holds findings.json + per-group md for the files objective.
const reportPath = writeReport ? `${auditDir}/${timestamp}-audit-report.md` : ''
const outDir = `${auditDir}/${timestamp}`

// `stableStringify` and `dataBlock` come from the shared prelude (#586) — see
// 15-prelude.js. The harness-specific note the prelude does not carry: array
// order is load-bearing HERE because findings are ref-indexed by `stampRefs`,
// so only key order is normalized, never element order. The per-domain fan-out
// is what makes the byte-stability matter (#256) — every domain scan re-sends
// the same prefix.
