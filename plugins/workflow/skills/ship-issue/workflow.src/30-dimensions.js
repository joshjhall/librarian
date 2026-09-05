
// Dimensions that reuse the code-reviewer agent's own Sub-Reviewer Definitions.
// `security` keeps its category; `bug` is the agent's correctness reviewer but
// we surface it under category=correctness to match the issue's dimension name.
const REUSED_DIMENSIONS = [
  { name: 'security', mode: 'security', category: 'security' },
  { name: 'correctness', mode: 'bug', category: 'correctness' },
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
      'difference between suggesting a split and accepting one.',
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
