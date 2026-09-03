
const READONLY =
  'This is a read-only review: do NOT edit, write, commit, branch, or push — ' +
  'and do NOT run any shell command that mutates or deletes files or git state ' +
  '(`rm`, `git clean`, `git checkout --`, `git reset --hard`, `mv`, `truncate`, ' +
  '`>`/`>>` redirection to a tracked path). If you must reproduce something, do ' +
  'it ONLY inside a fresh `mktemp -d` sandbox, never against the working tree. ' +
  'Canonicalize any path (`cd <dir> && pwd`) before a destructive op; never pass ' +
  'an unresolved `..`. ' +
  'Run at the code-reviewer agent model tier (sonnet).'

// Exploration bounds (#553). The diff and its classifications are supplied
// below — reviewers do NOT need to rediscover them. Measured on the #471/#472
// run, reviewers nonetheless ranged over the whole repo: `security` spent 128
// turns / 115 Bash calls on a 2-file diff, `conventions` 63 turns / 63. Each
// tool call re-sends the accumulated context, so an unbounded search multiplies
// cost superlinearly in turns while adding little the diff does not already
// show. This is guidance, not enforcement — `agent()` exposes no turn cap — so
// the caller-supplied token ceiling remains the actual backstop. Static text:
// appended identically to every reviewer prompt, so the cacheable shared prefix
// (#256) stays byte-identical across the fan-out.
const SCOPE_DISCIPLINE =
  'Scope discipline: the changed files, their classifications, and the full diff ' +
  'are provided below — do not re-derive them. Budget yourself roughly 10 tool ' +
  'calls; spend them only where the diff itself is genuinely ambiguous. Prefer ' +
  'reading a changed file over grepping the repo. Open an UNCHANGED file only ' +
  'when a specific finding depends on its contents (e.g. confirming a caller ' +
  'signature you are about to flag), and say so in that finding. Do NOT survey ' +
  'the repo for related patterns, audit unchanged code, or verify project-wide ' +
  'conventions beyond the diff — findings must be anchored to a changed line. ' +
  'If you cannot confirm something within that budget, report it at LOW ' +
  'certainty rather than searching further: the judge re-scores certainty, and ' +
  'a LOW-certainty finding is filed, never dropped. ' +
  // #557: the measured worst case was a reviewer spending six consecutive Bash
  // calls re-rolling an awk one-liner to count over-long lines, then hunting for
  // the rumdl config, then re-running rumdl and shellcheck by hand — all of it
  // recomputing what CI already enforces. Mechanical, tool-decidable facts are
  // exactly what the reviewer should NOT be spending context on.
  'Formatting, linting, spelling, and style rules are enforced by the repo\'s ' +
  'own gates in CI (this repo: rumdl, shellcheck, typos, ruff, and the ' +
  'tests/lint-*.sh gates), which block merge on their own. Do NOT re-run those ' +
  'tools, hunt for their config, or hand-measure what they check (line length, ' +
  'quoting, spelling, import order, formatting) — a merged PR has already ' +
  'passed them. Any such results supplied below are authoritative; treat them ' +
  'as settled and spend your budget on what a linter CANNOT decide: logic, ' +
  'security, missing tests, and violations of documented project conventions.'

// END SCOPE_DISCIPLINE — do not move this marker; tests/workflow-helpers/
// ship-issue/06-prescan-conventions.mjs slices the clause above by anchoring on
// it (#586: it previously anchored on a prose comment that a later edit
// duplicated earlier in the file, silently emptying the slice and failing six
// assertions).
//
// `sanitize` and `dataBlock` — the prompt-injection controls — arrive in the
// generated prelude fragment (15-prelude.js), which loads above NEW_DIMENSIONS
// so `sanitize` is initialized before that module-load call; the prompt builders
// below consume them.

// Manifest header. On a narrowed re-review cycle (#492) the caller-supplied
// `files`/`diff` args are replaced with the fix-commit delta (`deltaFiles`/
// `deltaDiff`) so the manifest's file list, classifications, and `needs`
// (specialist gating) describe what actually changed this cycle, not the whole PR.
const scopeHeader = (files, diff) => {
  const fileList = files.length
    ? `Review scope (files): ${files.join(', ')}\n`
    : 'No explicit file list provided — derive scope from `git diff --name-only origin/main...HEAD`.\n'
  const diffBlock = diff ? `\nProvided diff for context:\n${dataBlock('DIFF', diff)}\n` : ''
  return fileList + diffBlock
}

// The diff a reviewer reads. Prefer the caller's byte-faithful `scopeDiff` (the
// skill's own `git diff` output) so findings cite `file:line` against real bytes,
// never a manifest transcription (#267). When no diff was supplied, instruct the
// (Bash-capable) reviewer to derive it in-agent — the deliberate no-args.diff
// fallback. NOTE: the fallback trades the pre-#267 single-snapshot guarantee for
// cost savings — each parallel reviewer runs its own `git diff`, so a working
// tree that mutates mid-barrier (plausible in a golem's ship context) could yield
// diffs inconsistent with the once-computed `manifest.files`/`classifications`.
// The skill always passes `diff` here (see ci-review-protocol.md /
// pre-ship-validation.md), so this path is a best-effort convenience only.
// The diff a reviewer reads — parameterized (#492) so each dimension can be
// handed either the fix-commit delta (delta-local dimensions on a narrowed cycle)
// or the full PR diff (scope-drift always; every dimension on a full cycle).
// Defaults to `scopeDiff` so the manifest/comment builders and any non-narrowing
// caller are unchanged.
const diffSection = (diff = scopeDiff) =>
  diff
    ? `Diff:\n${dataBlock('DIFF', diff)}\n\n`
    : 'No diff supplied — derive it yourself with `git diff origin/main...HEAD` ' +
      'and review those changes.\n\n'

// On a narrowed re-review cycle the manifest is built over the fix-commit delta
// (deltaFiles/deltaDiff) so its file list, classifications, and `needs` describe
// what actually changed this cycle — the specialist gating and the delta-relevance
// tests then key off the real changed set. On cycle 1 / no delta it is the full
// scope, as before.
const manifestPrompt = () => {
  const narrowed = narrowingActive(CYCLE, deltaDiff, deltaFiles)
  const mFiles = narrowed ? deltaFiles : scopeFiles
  const mDiff = narrowed ? deltaDiff : scopeDiff
  return (
    `Mode: manifest.\n${scopeHeader(mFiles, mDiff)}\n` +
    `Follow Steps 1-2 of your instructions: build the changed-file manifest, read each ` +
    `file for context, and classify every file's type(s) — including \`docs\` for ` +
    `markdown/rst/adoc prose, which is a first-class type, not an absence of one. ` +
    `Decide which conditional ` +
    `specialists are needed: set needs.database=true if any file is type database, and ` +
    `needs.devops=true if any file is type ci or docker. Return the typed manifest ` +
    `(files, per-file classifications, needs) — do NOT echo the diff back. ` +
    READONLY
  )
}

// Byte-identical shared context across every reviewer dimension in a fan-out:
// the changed-file list, the manifest classifications (deterministically
// serialized), and the diff. Both reviewer prompt builders lead with the static
// READONLY contract and this shared block, appending ONLY the per-dimension
// mode/category token at the tail — so sibling reviewers share the maximal
// byte-identical prompt prefix and diverge only in their trailing selector
// (#256, cache-stability smells #1/#4). Leading with READONLY also keeps the
// safety contract anchored BEFORE the untrusted fenced diff (injection posture).
// Note: within one parallel() barrier the siblings cannot read each other's
// in-flight cache write, so the direct payoff is cross-cycle (a re-review whose
// diff is unchanged) plus resume determinism; the always-free shared prefix is
// the agent system-prompt + tool defs, identical across siblings regardless.
// Pre-scan candidates block (#556). Empty string when none were supplied, so an
// absent `preScan` leaves the shared prefix byte-identical to pre-#556 — the
// no-op case must not perturb the cache (#256).
//
// Only the five contract fields are forwarded, rebuilt in fixed order: the
// caller's objects are untrusted (they carry regex matches against file
// content), so an unexpected extra key must not ride into the prompt. dataBlock
// then fences the whole thing as data-only, matching how the diff and findings
// are handled everywhere else.
const preScanSection = () => {
  if (preScan.length === 0) return ''
  const rows = preScan.map((c) => ({
    file: c.file,
    line: c.line,
    category: c.category,
    evidence: typeof c.evidence === 'string' ? c.evidence : '',
    certainty: typeof c.certainty === 'string' ? c.certainty : '',
  }))
  return (
    'Deterministic pre-scan candidates, already computed by the repo scanner — ' +
    'do NOT re-derive them. Each is a regex match, NOT a confirmed finding: the ' +
    'scanner cannot see cross-directory tests, project conventions, or intent. ' +
    'Confirm the ones that are real (file them as your own findings, with your ' +
    'own certainty) and dismiss the rest — a dismissed candidate costs nothing, ' +
    'a re-derived one costs a repo search. They do not bound you: file anything ' +
    'else you find.' +
    (preScanTruncated > 0
      ? ` NOTE: ${preScanTruncated} further candidate(s) were omitted for size — this list is NOT exhaustive.`
      : '') +
    '\n' +
    dataBlock('PRE-SCAN CANDIDATES', rows) +
    '\n\n'
  )
}

// Conventions digest block (#557). Empty when not supplied, so the no-op case
// stays byte-identical to pre-#557 (#256). Fenced as data-only like every other
// caller-supplied block: the digest is distilled from repo files, which are
// themselves untrusted content in the injection model.
const conventionsSection = () => {
  if (!conventionsDigest) return ''
  return (
    'Project conventions, already distilled from this repo\'s CLAUDE.md / ' +
    'AGENTS.md / .claude/memory — do NOT re-read those files to rediscover ' +
    'them. Cite the specific rule when you flag a violation. This digest is a ' +
    'summary, not the whole ruleset' +
    (conventionsDigestTruncated ? ' AND IT WAS TRUNCATED for size' : '') +
    ': if the diff plainly violates a documented convention that is absent ' +
    'here, still flag it.\n' +
    dataBlock('PROJECT CONVENTIONS', conventionsDigest) +
    '\n\n'
  )
}

const reviewerData = (manifest, diff = scopeDiff) =>
  `Changed files: ${manifest.files.join(', ') || '(see diff)'}\n` +
  `Classifications: ${stableStringify(manifest.classifications)}\n\n` +
  conventionsSection() +
  preScanSection() +
  diffSection(diff)

// Reused dimensions (security, correctness): defer to the agent's own
// Sub-Reviewer Definition, only overriding the surfaced category name.
const reusedReviewerPrompt = (dim, manifest, diff = scopeDiff) =>
  READONLY +
  '\n' +
  SCOPE_DISCIPLINE +
  '\n\n' +
  reviewerData(manifest, diff) +
  `Mode: reviewer:${dim.mode}. Analyze the changed files and diff above as the ` +
  `${dim.mode} sub-reviewer using the corresponding Sub-Reviewer Definition in ` +
  `your instructions. Set category=${dim.category} on every finding and return ` +
  `the typed findings array (empty if none).`

// New dimensions (tests, conventions, decomposition, scope-drift): instructions supplied inline.
const newReviewerPrompt = (dim, manifest, diff = scopeDiff) =>
  READONLY +
  '\n' +
  SCOPE_DISCIPLINE +
  '\n\n' +
  reviewerData(manifest, diff) +
  `Mode: reviewer:${dim.name} (custom dimension). Analyze the changed files and ` +
  `diff above.\n${dim.instructions}\n\n` +
  `Set category=${dim.category} on every finding and return the typed findings ` +
  `array (empty if none), using the same finding schema as your other reviews.`

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
  diffSection() +
  `Open PR review comments:\n${dataBlock('PR_COMMENTS', prComments)}\n\n` +
  READONLY

// One fresh-judge prompt that does BOTH jobs the old rescorePrompt + classifyPrompt
// did — re-score certainty AND characterize the finding — in a single pass, keyed
// per finding by `ref` (#491).
//
// What changed in #580: the judge no longer applies a blocking-vs-deferrable
// policy. It reports two OBSERVATIONS (certainty, nature) and `dispositionOf`
// derives the disposition. The old prose policy was unsatisfiable (see the
// JUDGE_SCHEMA header), and no amount of prose could be tested — a rule list in
// code can. Asking the judge for what it can actually observe, rather than for a
// verdict it must derive through a policy it cannot be held to, is the fix.
//
// The changed-file list is supplied because `defect-in-new-code` vs
// `defect-in-preexisting-code` is undecidable without it: the judge previously
// saw findings ONLY, with no view of what this PR touched.
const judgePrompt = (findings, budgetExhausted, files = scopeFiles) =>
  `Mode: judge. You are a FRESH judge — you did NOT produce these findings.\n` +
  `For EACH finding below do BOTH of the following, and return exactly one verdict ` +
  `per finding:\n\n` +
  `1. Re-score its certainty (level + confidence) independently, based solely on the ` +
  `evidence in its description and suggestion. Do not add, remove, merge, or ` +
  `otherwise alter any finding.\n\n` +
  `2. Characterize it with exactly one \`nature\`. This is an OBSERVATION about ` +
  `the finding, not a decision about what blocks the merge — that is computed ` +
  `downstream from your answer, so report what you see and do not try to reason ` +
  `about consequences:\n` +
  `  - defect-in-new-code: a real defect (wrong behavior, a silent failure, a ` +
  `test that cannot fail, a security hole) located in code THIS PR wrote or ` +
  `changed. The changed-file list below is authoritative for "this PR wrote it".\n` +
  `  - defect-in-preexisting-code: a real defect, but in code this PR did not ` +
  `touch — it merely became visible during review.\n` +
  `  - incomplete-work: the PR does not do what it claims — an acceptance ` +
  `criterion is unaddressed, a stated goal is only partially implemented, or a ` +
  `change is missing a counterpart it plainly requires.\n` +
  `  - improvement: a valid suggestion that is not a defect — style, naming, ` +
  `structure, performance not tied to a correctness or security risk, or a ` +
  `genuinely out-of-scope enhancement belonging in its own issue.\n` +
  `When a finding could read as either a defect or an improvement, ask whether ` +
  `the code is WRONG or merely not as nice as it could be. Only "wrong" is a ` +
  `defect. When a defect straddles new and pre-existing code, choose ` +
  `defect-in-new-code if this PR's change is what makes it reachable or wrong.\n` +
  (budgetExhausted
    ? `NOTE: the budget was exhausted this cycle — the certainty you assign is ` +
      `the only signal downstream, so score conservatively rather than ` +
      `overstating confidence you could not verify.\n`
    : '') +
  `Key each verdict back to its finding by the \`ref\` field carried on that ` +
  `finding — copy it verbatim (it is a unique id; do not reconstruct it from other ` +
  `fields).\n\n` +
  `Files changed by this PR: ${files.join(', ') || '(unknown — treat every finding as pre-existing unless its evidence shows otherwise)'}\n\n` +
  `Findings to judge:\n${dataBlock('FINDINGS', findings)}\n\n` +
  READONLY
