// =============================================================================
// Orchestration — Map -> Scan -> Verify -> Aggregate -> File (the cohesive loop;
// this is the only part that runs side effects, and it stays together).
// =============================================================================

log(`codebase-audit (depth: ${depth}, threshold: ${severityThreshold}, output: ${output}, report: ${writeReport})`)

// --- Map --------------------------------------------------------------------
phase('Map')

// Dispatched through `attempt` so a THROW is reported as a result envelope
// rather than crashing the audit (#646). `agent()` fails two ways — a terminal
// API error returns null, StructuredOutput retry-cap exhaustion throws — and
// only the first ever reached the guard below.
const mapAttempt = await attempt(
  () =>
    agent(mapPrompt(), {
      label: 'map',
      phase: 'Map',
      agentType: 'review-audit:checker',
      schema: MAP_SCHEMA,
    }),
  'map'
)

if (!mapAttempt.ok) {
  return finalResult({ report_markdown: mapFailureNote(mapAttempt.threw, mapAttempt.error) })
}

const map = mapAttempt.value
for (const p of map.excluded) log(`excluded from scan: ${p}`)

let domains = map.domains
if (onlyCategories) {
  // Belt-and-suspenders: the map prompt already restricts, but enforce here too.
  domains = domains.filter((d) => onlyCategories.includes(d.name) || onlyCategories.includes(d.scanner))
}
if (domains.length === 0) {
  return finalResult({ platform: map.platform, report_markdown: 'No scanner domains matched the scope/categories.' })
}
log(`mapped ${domains.length} domain(s): ${domains.map((d) => d.name).join(', ')}`)

// --- Scan (fan-out, NO barrier) ---------------------------------------------
// Every domain scans concurrently; there is no per-domain verify stage anymore.
// The adversarial verify is ONE barrier over the whole finding set below
// (issue #490) — collapsing the old O(domains) per-domain judge passes to O(1),
// symmetric to the aggregate barrier that already runs a single checker pass
// over the same collected set.
phase('Scan')
let budgetExhausted = false
// Tracked separately from budgetExhausted: a null agent result is an agent
// failure (timeout / crash / schema reject), NOT budget exhaustion. Conflating
// them would tell the caller "re-run with more budget" when the real cause was
// an agent error. Both still mark the audit partial.
let hadScanFailure = false
// Domains dropped before producing findings, tracked BY NAME (not just the
// booleans above) so the durable report can name the coverage gaps (#262). Only
// scan-skip / scan-fail land here — the verify barrier below keeps its findings
// on a budget skip (fail-open), so a scanned domain is never a coverage gap.
const skippedDomains = []

const scanned = await pipeline(
  domains,
  // Scan one domain. Budget-gated INSIDE the thunk so mid-fan-out exhaustion is
  // seen (a synchronous pre-check during list build would not).
  (domain) => {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      budgetExhausted = true
      skippedDomains.push({ name: domain.name, reason: 'budget low — scan skipped' })
      log(`budget low — skipped scan of domain "${domain.name}" (not in this audit)`)
      return Promise.resolve(null)
    }
    return agent(scanPrompt(domain), {
      label: `scan:${domain.name}`,
      phase: 'Scan',
      agentType: 'review-audit:checker',
      schema: SCAN_SCHEMA,
    }).then((r) => {
      if (!r) {
        hadScanFailure = true
        skippedDomains.push({ name: domain.name, reason: 'scan failed' })
        log(`scan FAILED for domain "${domain.name}" — omitted from this audit`)
        return null
      }
      return {
        domain: domain.name,
        scanner: r.scanner,
        findings: stampRefs(domain.name, r.findings || []),
        acknowledged: r.acknowledged_findings || [],
        files_scanned: r.files_scanned || domain.files.length,
      }
    })
  },
)

// Assemble the scanned set. `pipeline` nulls any item whose stage threw, and the
// scan thunk also returns null on a budget skip / scan failure — both already
// logged above, so filtering here drops nothing silently.
const scannedDomains = []
const acknowledgedAll = []
let allFindings = []
for (const r of scanned) {
  if (!r) continue
  scannedDomains.push(r.domain)
  for (const a of r.acknowledged) acknowledgedAll.push(a)
  for (const f of r.findings) allFindings.push(f)
}

// --- Verify (ONE barrier over the full finding set) -------------------------
// A single fresh adversarial checker re-scores certainty and refutes false
// positives across EVERY domain's findings at once — no producer self-grading,
// and exactly one judge call per audit regardless of domain count (#490).
// Findings carry a globally-unique `ref` (stampRefs prefixes the domain), so one
// verify keyed by ref maps back correctly — the same invariant aggregate relies
// on. Skipped only when there is nothing to judge (no findings). Fail-open on a
// budget skip or a verify failure: keep the unverified findings, never drop a
// real one silently.
phase('Verify')
if (allFindings.length > 0) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) {
    budgetExhausted = true
    log('budget low — kept all findings UNVERIFIED (re-run to adversarially verify)')
  } else {
    // Route through tailAgent: this is a TERMINAL single-agent stage (it runs
    // after every scan and holds the whole finding set), so a throw here is NOT
    // caught by pipeline()/parallel() and would kill the run
    // AFTER every scan completed — discarding every finding instead of failing
    // open. tailAgent turns a throw / mid-tail budget overshoot into a null,
    // which the fail-open branch below already handles (same guard the aggregate
    // and artifact-writer tail calls use).
    const v = await tailAgent(
      () =>
        agent(verifyPrompt(allFindings), {
          label: 'verify',
          phase: 'Verify',
          agentType: 'review-audit:checker',
          // Pin the adversarial judge to opus: a false verdict here either drops
          // a real finding or ships a false positive, so quality compounds. The
          // leverage is the adversarial framing plus a context that did not
          // produce the findings, not the tier — opus holds the bar without
          // fable's premium on a stage that reads every finding (#526).
          model: 'opus',
          schema: VERIFY_SCHEMA,
        }),
      'verify'
    )
    if (!v) {
      // Verify failed / was budget-skipped mid-tail — keep findings (fail-open)
      // so nothing is silently lost. Flag budget_exhausted only when the budget
      // is genuinely the cause (a tail overshoot), mirroring the aggregate null
      // path, so the caller isn't told "re-run with more budget" on a plain
      // agent failure.
      if (budgetLow()) budgetExhausted = true
      log('verify FAILED — keeping all findings unverified')
    } else {
      const before = allFindings.length
      allFindings = applyVerifyScores(allFindings, v.scores)
      const dropped = before - allFindings.length
      if (dropped > 0) log(`verify dropped ${dropped} refuted finding(s)`)
    }
  }
}

if (allFindings.length === 0) {
  log('no confirmed findings across all domains — codebase looks clean')
  // Append the coverage caveat BEFORE the writer call so the "0 findings" line
  // can never stand alone over partial coverage in the persisted artifact (#262).
  const cleanReport =
    `# Codebase Audit Report\n\n0 findings across ${scannedDomains.length} domain(s): ${scannedDomains.join(', ') || '(none)'}.\n` +
    coverageSection(scannedDomains, skippedDomains)
  // A clean audit is still a durable artifact when a report was requested — the
  // "always produce artifacts" objective holds even at zero findings.
  let cleanArtifacts = null
  let cleanReportPath = ''
  if (writeReport) {
    phase('File')
    const art = await tailAgent(
      () =>
        agent(artifactWriterPrompt('', reportPath, cleanReport, [], [], { critical: 0, high: 0, medium: 0, low: 0 }), {
          label: 'report',
          phase: 'File',
          agentType: 'review-audit:artifact-writer',
          schema: ARTIFACT_WRITER_SCHEMA,
        }),
      'report artifact-writer'
    )
    if (art) {
      cleanArtifacts = art
      cleanReportPath = art.report_path
      log(`wrote report summary to ${art.report_path || reportPath}`)
    } else {
      // Report skipped/failed on a clean audit. Only flag budget_exhausted when
      // the budget is genuinely the cause; a plain writer failure leaves the flag
      // honest (the clean audit still returns its in-memory report_markdown).
      if (budgetLow()) budgetExhausted = true
      log('report artifact-writer failed — clean audit, nothing else to write')
    }
  }
  return finalResult({
    platform: map.platform,
    scanned_domains: scannedDomains,
    report_markdown: cleanReport,
    report_path: cleanReportPath,
    artifacts: cleanArtifacts,
    acknowledged: acknowledgedAll.length,
    budget_exhausted: budgetExhausted,
    scan_failure: hadScanFailure,
    skipped_domains: skippedDomains,
    summary: { domains: scannedDomains.length, findings: 0, groups: 0, dropped_groups: 0, filed: 0, skipped: 0, errored: 0 },
  })
}

// --- Aggregate (barrier: needs the full verified set to dedup + correlate) ---
phase('Aggregate')

const aggregate = await tailAgent(
  () =>
    agent(aggregatePrompt(allFindings, acknowledgedAll), {
      label: 'aggregate',
      phase: 'Aggregate',
      agentType: 'review-audit:checker',
      schema: AGGREGATE_SCHEMA,
    }),
  'aggregate'
)

if (!aggregate) {
  // Without grouping we cannot file safely — return the raw findings as a report
  // rather than open misgrouped issues. Only flag budget_exhausted when the
  // budget is genuinely the cause (a tail skip/overshoot), NOT for a plain
  // aggregate-agent failure — the two are kept distinct so the caller isn't told
  // "re-run with more budget" when the real cause was an agent error. Either way
  // scan_failure below marks the audit partial.
  if (budgetLow()) budgetExhausted = true
  log('aggregate step failed — returning raw findings without filing')
  return finalResult({
    platform: map.platform,
    scanned_domains: scannedDomains,
    report_markdown:
      `Aggregate failed. ${allFindings.length} confirmed finding(s) across ${scannedDomains.length} domain(s); re-run to group + file.\n` +
      coverageSection(scannedDomains, skippedDomains),
    // Don't conflate an aggregate-agent failure with budget exhaustion (same
    // bug class as the scan path): report the real budget state, and mark the
    // audit a scan-pipeline failure so the caller knows it is partial.
    budget_exhausted: budgetExhausted,
    scan_failure: true,
    skipped_domains: skippedDomains,
    summary: { domains: scannedDomains.length, findings: allFindings.length, groups: 0, dropped_groups: 0, filed: 0, skipped: 0, errored: 0 },
  })
}

// Map refs back to the full finding objects the harness still holds (the model
// returned refs only, so nothing was re-serialized / lost).
const byRef = new Map(allFindings.map((f) => [f.ref, f]))
const mappedGroups = aggregate.groups.map((g) => {
  const findings = g.finding_refs.map((r) => byRef.get(r)).filter(Boolean)
  const missing = g.finding_refs.length - findings.length
  if (missing > 0) log(`group "${g.title}" referenced ${missing} unknown finding ref(s) — omitted`)
  return { group: g, findings }
})
// A group whose refs ALL fail to resolve is NOT a silent no-op: it means the
// aggregate step grouped real findings but emitted refs the harness can't map
// back, so those findings would vanish from every issue. Surface it loudly and
// count it so summary.dropped_groups != 0 flags aggregate ref drift to the
// caller, rather than the group just disappearing.
const droppedGroups = mappedGroups.filter((g) => g.findings.length === 0)
for (const g of droppedGroups) {
  log(`group "${g.group.title}" had NO resolvable finding refs — its findings are not filed (aggregate ref mismatch)`)
}
const groups = mappedGroups.filter((g) => g.findings.length > 0)

// Append the coverage caveat to the aggregate agent's report ONCE, so the
// in-memory envelope (reportTail) and the file the artifact-writer persists agree
// — both use this local rather than the raw aggregate.report_markdown (#262).
const reportMarkdown = aggregate.report_markdown + coverageSection(scannedDomains, skippedDomains)

const reportTail = {
  platform: map.platform,
  scanned_domains: scannedDomains,
  totals: aggregate.totals,
  report_markdown: reportMarkdown,
  acknowledged: acknowledgedAll.length,
  budget_exhausted: budgetExhausted,
  scan_failure: hadScanFailure,
  skipped_domains: skippedDomains,
}

// Base summary shared by every File-phase return; per-return fields override.
const baseSummary = {
  domains: scannedDomains.length,
  findings: allFindings.length,
  groups: groups.length,
  dropped_groups: droppedGroups.length,
  filed: 0,
  skipped: 0,
  errored: 0,
}

// --- File (route by objective: write files, or fan out issue-writer) ---------
phase('File')

// Dispatch the artifact-writer for file output. `dirForFindings` is '' for a
// report-only dispatch (issues objective + writeReport) so only the report md
// is written. Returns the raw StructuredOutput (or null on agent failure OR a
// budget-exhausted tail — tailAgent keeps a ceiling hit from throwing the whole
// audit away after every scan+verify+aggregate already completed).
const writeArtifacts = (dirForFindings) =>
  tailAgent(
    () =>
      agent(artifactWriterPrompt(dirForFindings, reportPath, reportMarkdown, allFindings, groups, aggregate.totals), {
        label: dirForFindings ? 'artifacts' : 'report',
        phase: 'File',
        agentType: 'review-audit:artifact-writer',
        schema: ARTIFACT_WRITER_SCHEMA,
      }),
    dirForFindings ? 'artifact-writer' : 'report artifact-writer'
  )

// Objective FILES — or ISSUES with no tracker to file into (the SKILL layer
// should prevent the latter, but the harness never mutates a tracker unprompted,
// so it coerces to file output and says so).
if (output === 'files' || map.platform === 'none') {
  if (output === 'issues') {
    log('no GitHub/GitLab platform detected — writing file artifacts instead of filing issues')
  }
  const art = await writeArtifacts(outDir)
  if (!art) {
    log('artifact-writer failed — no files written')
    return finalResult({
      ...reportTail,
      // reportTail froze budget_exhausted before this write; if the writer was
      // skipped for BUDGET (not a plain agent failure), reflect that here.
      budget_exhausted: budgetLow() || reportTail.budget_exhausted,
      artifacts: { action: 'error', out_dir: '', files_written: [], report_path: '', reason: 'artifact-writer failed (no result returned)' },
      scan_failure: true,
      summary: { ...baseSummary },
    })
  }
  log(`wrote ${art.files_written.length} file artifact(s) to ${art.out_dir || auditDir}`)
  return finalResult({
    ...reportTail,
    report_path: art.report_path,
    artifacts: art,
    summary: { ...baseSummary },
  })
}

// Objective ISSUES — parallel issue-writer fan-out (dedupe-before-create).
const outcomes = await parallel(
  groups.map((g) => () =>
    agent(issueWriterPrompt(map.platform, g.group, g.findings), {
      label: `file:${g.group.category}`,
      phase: 'File',
      agentType: 'review-audit:issue-writer',
      schema: ISSUE_WRITER_SCHEMA,
    })
  )
)

const issues = []
let filed = 0
let skipped = 0
let errored = 0
outcomes.forEach((o, i) => {
  if (!o) {
    errored += 1
    const g = groups[i].group
    issues.push({ action: 'error', url: '', title: g.title, reason: 'issue-writer failed (no result returned)' })
    log(`issue-writer failed for group "${g.title}"`)
    return
  }
  issues.push(o)
  if (o.action === 'created') filed += 1
  else if (o.action === 'skipped') skipped += 1
  else errored += 1
})

log(`filed ${filed} issue(s), skipped ${skipped} duplicate(s), ${errored} error(s)`)

// The report summary accompanies filed issues via a report-only artifact-writer
// dispatch (no findings.json / group files — just the ./audit report md).
let artifacts = null
let artifactReportPath = ''
let reportBudgetSkipped = false
if (writeReport) {
  const art = await writeArtifacts('')
  if (art) {
    artifacts = art
    artifactReportPath = art.report_path
    log(`wrote report summary to ${art.report_path || reportPath}`)
  } else {
    // Issues were still filed; only the accompanying report md is missing. Flag
    // budget_exhausted below only if the budget was genuinely the cause.
    reportBudgetSkipped = budgetLow()
    log('report artifact-writer failed — issues were still filed')
    artifacts = { action: 'error', out_dir: '', files_written: [], report_path: '', reason: 'report artifact-writer failed (no result returned)' }
  }
}

return finalResult({
  ...reportTail,
  // reportTail froze budget_exhausted before the report write; surface a
  // budget-skipped report so a truncated tail is visible even though issues filed.
  budget_exhausted: reportBudgetSkipped || reportTail.budget_exhausted,
  issues,
  report_path: artifactReportPath,
  artifacts,
  summary: { ...baseSummary, filed, skipped, errored },
})
