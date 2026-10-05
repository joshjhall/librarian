
// Dimensions that reuse the code-reviewer agent's own Sub-Reviewer Definitions.
// `security` keeps its category; `bug` is the agent's correctness reviewer but
// we surface it under category=correctness to match the issue's dimension name.
//
// `security` also carries inline `instructions` (#1138). The Sub-Reviewer
// Definitions moved out of the agent body into the code-review harness's
// SUBREVIEWERS map (#494/#524), and only THAT harness pastes them — so this
// harness's security reviewer was told to follow a definition it never received.
// With no checklist it skimmed the diff: across the post-#1111 cycle results it
// was the ONLY dimension still unengaged (every `checked` entry `diff-only`)
// after the opus retry, 4 of the 8 cycles that retried it.
//
// correctness had the same dangling reference (#1146). It engaged anyway, so the
// symptom was quieter: it reviewed WITHOUT the bug checklist's Error Handling and
// Concurrency Red Flags — the silent-failure shapes this repo keeps filing. It
// carries BUG_CHECKLIST, a VERBATIM copy of the code-review harness's
// SUBREVIEWERS.bug (plugins/dev-core/agents/code-reviewer/workflow.js). A copy,
// not a shared source: the two harnesses sit in different plugins, and a
// workflow.js cannot import (#712). The copies cannot drift silently —
// tests/workflow-helpers/ship-issue/11-engagement-floor.mjs area (5) reads the
// REAL map and asserts byte equality, so edit both together.
//
// Every REUSED_DIMENSIONS entry MUST carry `instructions` (pinned in that same
// area): the agent body no longer holds any Sub-Reviewer Definition to fall back
// on.
const SECURITY_INSTRUCTIONS =
  'You MUST open (Read) every changed code file before answering, and record ' +
  'each in `checked` with how="read". A diff-only answer is NOT a security ' +
  'review and is rejected as unengaged: a diff hunk hides the guard above it, ' +
  'the caller that feeds it, and the sink it reaches, which is exactly where ' +
  'security defects live. Answer these from the code, not the hunk:\n' +
  '- Fail-closed: does every new error path, early return, `|| true`, empty ' +
  'catch, or default value fail CLOSED (refuse) rather than open (proceed as ' +
  'if checked)?\n' +
  '- Interpolation: does untrusted input or MODEL OUTPUT newly reach a prompt, ' +
  'shell command, file path, regex, URL, or query without fencing, quoting, or ' +
  'validation?\n' +
  '- Sinks: is there a new shell exec, file write/delete, or network call — and ' +
  'is its path canonicalized and contained, and its input bounded?\n' +
  '- Secrets: are credentials, tokens, or env values newly logged, echoed, ' +
  'committed, or passed to a subprocess that does not need them?\n' +
  '- The rest of the OWASP set where the changed code can reach it: injection, ' +
  'authn/authz bypass, path traversal, SSRF, insecure deserialization, weak ' +
  'crypto.\n' +
  'Empty `findings` is a valid answer only after you have read the files.'

const BUG_CHECKLIST =
  'You are a bug-focused code reviewer. Analyze the provided code changes for\n' +
  'correctness issues.\n\n' +
  'Check for:\n\n' +
  '- Logic errors and off-by-one mistakes\n' +
  '- Null/undefined access and type confusion\n' +
  '- Race conditions and data races\n' +
  '- Incorrect boolean logic or operator precedence\n' +
  '- Missing return statements or unreachable code\n' +
  '- Incorrect use of APIs (wrong argument order, deprecated methods)\n\n' +
  'Error Handling Red Flags — flag every occurrence:\n\n' +
  '- Generic base exceptions instead of specific error types\n' +
  '- Exceptions with no structured context (just a message string)\n' +
  '- Swallowed exceptions (empty catch blocks or catch-and-ignore)\n' +
  '- Duplicate logging (manual log + auto-logging exception)\n' +
  '- Retrying permanent failures (auth errors, validation errors)\n\n' +
  'Concurrency Red Flags — flag every occurrence:\n\n' +
  '- Async operations without timeout limits\n' +
  '- Connections or file handles not cleaned up on error paths\n' +
  '- Batch operations that stop entirely on first failure (should accumulate)\n' +
  '- Missing exponential backoff or jitter on retries'

const REUSED_DIMENSIONS = [
  { name: 'security', mode: 'security', category: 'security', instructions: SECURITY_INSTRUCTIONS },
  { name: 'correctness', mode: 'bug', category: 'correctness', instructions: BUG_CHECKLIST },
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
  // NOTE — there is deliberately no `conventions` entry here (#551). It was
  // demoted from the inline fan-out because the repo already gates most of what
  // its instructions asked for, deterministically and for free, on every PR:
  // lint-shellcheck.sh, lint-shell-portability.sh, lint-action-pins.sh,
  // lint-skills-agents.sh, lint-command-refs.sh and conform (.conform.yaml).
  // Measured cost on the #471/#472 run: 84 turns (cycle 1) and 139 turns /
  // 63 Bash calls (cycle 2), ~4.6M and ~7.8M cache_read — paid every cycle of
  // every PR, largely re-deriving what those gates compute.
  //
  // The `conventionsDigest` arg is NOT part of that demotion and stays: it
  // renders into `reviewerData()`, the prefix EVERY surviving dimension reads,
  // so dropping it would degrade the other five and re-open #557. Demoting the
  // dimension and deleting the digest are separate changes; only the first
  // happened.
  //
  // Where the demoted coverage went, and what nothing covers now:
  // ship-issue/conventions-coverage.md.
  {
    name: 'decomposition',
    category: 'decomposition',
    instructions:
      'You are a file-size / decomposition reviewer (#695). The pre-scan has ' +
      'already computed production LOC and growth for the changed files — read ' +
      'its `file-length` and `decomposition-seam` candidates and judge what the ' +
      'numbers cannot: whether a proposed seam is SEMANTICALLY coherent (do those ' +
      'lines actually belong together, and does the destination name describe ' +
      'them?), and whether a declined file was RIGHTLY declined.\n' +
      'GROWTH-AWARE, NOT ABSOLUTE. Never flag a file for size this diff did not ' +
      'meaningfully change: a one-line touch to a pre-existing 1,200-line file is ' +
      'not this PR\'s debt, and the pre-scan already marks that case LOW/' +
      'informational. Flag when the diff PUSHES a file over a threshold, or adds ' +
      'materially to one already over.\n' +
      'DEFERRABLE-LEANING. The right outcome is usually a follow-up issue, not a ' +
      'blocked PR. Only treat size as blocking when the growth is both large and ' +
      'plainly severable in this change.\n' +
      'EVERY FINDING MUST NAME A CONCRETE SEAM — which lines move, and where to. ' +
      'A finding that says only "this file is long" or "consider splitting" is ' +
      'worthless and must not be filed; if you cannot name the cut, say the file ' +
      'was examined and declined, and why.\n' +
      'Split guidance is LANGUAGE-SHAPED: Rust -> new subdir module with mod.rs ' +
      're-exporting; Python -> package dir with __init__.py re-exporting the ' +
      'public surface; JS/TS -> sibling modules + a barrel index.ts; Go -> more ' +
      'files in the same package (no import churn); Shell -> a sourced fragment ' +
      'plus an explicit ordered list; Markdown -> PROGRESSIVE DISCLOSURE, moving ' +
      'detail into linked files and leaving a one-line pointer behind. For ' +
      'markdown especially, a split that moves prose out with NO link left behind ' +
      'has lost content, not decomposed it — say so.\n' +
      'Long-and-correct is a real answer: a generated file, a lookup table, one ' +
      'exhaustive match arm are legitimately long. Do not manufacture findings.\n' +
      'WHEN THE DIFF ITSELF PERFORMS A SPLIT — a file shrank sharply and sibling ' +
      'files appeared, or prose moved into new linked docs — do not eyeball ' +
      'whether it lost anything. Say so in your finding and cite ' +
      '`ship-issue/split-verify.sh <pre-split-snapshot> <post-split-original> ' +
      '[<destination> ...]`, which proves it mechanically: production-LOC ' +
      'conservation, every top-level unit preserved, no dangling callers, and ' +
      'for markdown every moved heading still reachable by a link. That is the ' +
      'difference between suggesting a split and accepting one.\n' +
      'MEMORY-BUNDLE CONFORMANCE (#699). This dimension also owns the pre-scan\'s ' +
      '`okf-*` and `memory-*` candidates for changed `.claude/memory/**` files. ' +
      'Folded in here rather than given a sixth dimension because this is the only ' +
      'dimension that already reads `docs`, so it already survives doc-only ' +
      'routing and already runs delta-local -- a sixth would cost a whole extra ' +
      'agent per cycle to re-establish all three properties.\n' +
      'STRUCTURE ONLY, never content quality. Judge whether the file parses, ' +
      'carries a `type`, is reachable from an index, and whether an index line ' +
      'resolves to a file that exists. Whether a memory is WORTH keeping, ' +
      'duplicates another, or sits in the wrong tier is the audit half\'s ' +
      'semantic pass -- advisory and human-reviewed. Wiring knowledge-quality ' +
      'judgment into a merge gate is how the dimension gets switched off.\n' +
      'DEFERRABLE-LEANING, more so than size. A malformed memory in a PR whose ' +
      'subject is something else should almost never block: it is a one-line fix ' +
      'the author can make in a follow-up. Block only when the PR\'s OWN subject ' +
      'is the memory bundle.\n' +
      'NEVER QUOTE MEMORY CONTENT. Cite the file, the category and the structural ' +
      'defect; the body text of a memory must not reach a PR comment or issue.',
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
        ? `\n\nIssue #${Number(issue.number) || 0}: ${sanitize(issue.title, 200)}`
        : '\n\n(No issue context provided — flag only obvious out-of-scope changes.)'),
  },
]
