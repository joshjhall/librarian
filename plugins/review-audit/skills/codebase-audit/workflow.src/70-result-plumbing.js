// --- Ref & result plumbing ---------------------------------------------------

// A finding's stable, UNIQUE id across the whole audit. The audit domain name
// prefixes file:line:category so two domains can't collide, and the trailing
// index disambiguates two findings sharing file+line+category within a domain —
// otherwise verify/aggregate would silently key one onto the other.
const stampRefs = (domainName, findings) =>
  findings.map((f, i) => ({ ...f, ref: `${domainName}:${f.file}:${f.line_start}:${f.category}#${i}` }))

// Apply a verify pass's scores to the findings it judged. A fresh adversarial
// checker returns one score per finding keyed by the unique `ref` the harness
// stamped; this drops the refuted ones and re-scores certainty on the rest.
// Pure (no I/O, never mutates its inputs) so validate-workflow-helpers.mjs can
// unit-test the refute/re-score/keep semantics offline. Rules:
//   - Drop a finding ONLY on an explicit refutation (is_real === false); an
//     unscored finding (no matching ref) is KEPT — a verify that omits a ref is
//     silence, not refutation, so nothing is lost.
//   - Return a NEW object per kept finding rather than mutating in place, so the
//     caller's original `findings` array is never altered (keeps every fail-open
//     path that returns the unverified findings, and any future reuse, safe).
const applyVerifyScores = (findings, scores) => {
  const byRef = new Map((scores || []).map((s) => [s.ref, s]))
  const confirmed = []
  for (const f of findings) {
    const s = byRef.get(f.ref)
    if (s && s.is_real === false) continue
    confirmed.push(
      s && s.certainty
        ? { ...f, certainty: { ...f.certainty, level: s.certainty.level, confidence: s.certainty.confidence } }
        : f
    )
  }
  return confirmed
}

// Render the persisted report's coverage caveat. `skipped` is the list of
// domains that never fully scanned ([{name, reason}] — budget-skipped or
// scan-failed), so the durable artifact names the gaps instead of reading as
// "audited clean" over partial coverage (issue #262 — "silence is not success").
// Returns '' when nothing was skipped, keeping a fully-covered report unchanged.
const coverageSection = (scanned, skipped) => {
  if (!Array.isArray(skipped) || skipped.length === 0) return ''
  const covered = Array.isArray(scanned) ? scanned : []
  const gaps = skipped.map((d) => `- ${d.name} — ${d.reason}`).join('\n')
  return (
    `\n## Coverage\n\n` +
    `Scanned ${covered.length} domain(s): ${covered.join(', ') || '(none)'}.\n\n` +
    `⚠️ ${skipped.length} domain(s) NOT audited (findings may exist here):\n${gaps}\n`
  )
}

function finalResult(extra) {
  return {
    scanner: 'codebase-audit',
    // The resolved objective for this run ('issues' | 'files'), replacing the
    // old boolean dry_run — the terminal phase always produces artifacts now.
    output,
    // Path of the written report summary md, or '' when none was written.
    report_path: extra.report_path || '',
    platform: extra.platform || 'none',
    scanned_domains: extra.scanned_domains || [],
    totals: extra.totals || { critical: 0, high: 0, medium: 0, low: 0 },
    report_markdown: extra.report_markdown || '',
    issues: extra.issues || [],
    // The artifact-writer outcome ({action,out_dir,files_written,...}), or null
    // when no files were written (e.g. issues objective with report disabled).
    artifacts: extra.artifacts || null,
    acknowledged: extra.acknowledged || 0,
    summary: extra.summary || { domains: 0, findings: 0, groups: 0, dropped_groups: 0, filed: 0, skipped: 0, errored: 0 },
    budget_exhausted: !!extra.budget_exhausted,
    // A scan/verify agent failed (distinct from budget exhaustion); the audit
    // is partial for a different reason than "ran out of tokens".
    scan_failure: !!extra.scan_failure,
    // Domains that never fully scanned ([{name, reason}] — budget-skipped or
    // scan-failed), so a caller sees WHICH coverage was lost, not just that the
    // audit was partial (issue #262). Empty when coverage was complete.
    skipped_domains: extra.skipped_domains || [],
  }
}

