#!/usr/bin/env node
// Unit-test the PURE, side-effect-free helpers inside every workflow.js harness.
//
// Why this gate exists (issue #78, item 1 — follow-up to the #18 review): the
// six workflow.js harnesses carry pure helpers — input sanitizers, prompt-data
// wrappers, ref stampers, result-shape constructors — that are security and
// correctness controls, yet had NO runtime coverage. The only existing checks
// (tests/lint-skills-agents.sh) are structural: `node --check`, meta purity,
// phase/meta consistency. None of them runs `sanitize('a\r\nb')` and asserts the
// newline is gone. A regression in `sanitize` (prompt-injection control) or
// `stampRefs` (verify/aggregate keying) would pass every existing gate while
// silently breaking the harness.
//
// THIS FILE IS A THIN ENTRY POINT (issue #564). The assertions live in
// per-harness area modules under tests/workflow-helpers/; the extraction
// machinery and the shared collect-all assertion surface live in tests/lib/.
// Adding a case means editing the ONE area file that owns that harness, and a
// reviewer diffing a change can tell from the path which harness it affects.
//
// Two properties this entry point is responsible for:
//
//   1. ONE aggregated pass/fail summary. Every area imports the same
//      tests/lib/mjs-assert.mjs instance (ES modules are singletons per
//      specifier), so assertions accumulate into one array and are reported once
//      below. No area calls process.exit.
//
//   2. NO area can mask its siblings. Assertions are collect-all by design, but
//      an area can still throw OUTSIDE an assertion (an extractHelpers TDZ
//      blow-up, a drifted slice boundary). Each run() is therefore called inside
//      try/catch: the throw is recorded as a failure attributed to its area, and
//      the remaining areas still execute. Pre-split, such a throw aborted the
//      whole file and every later block was silently never run.
//
// Zero external dependencies (node built-ins only), like
// tests/validate-manifests.mjs — portable to host + container, no install step.

import { recordFailure, report, setArea } from "./lib/mjs-assert.mjs";
import { selfCheck } from "./lib/extract-helpers.mjs";

import { run as codebaseAudit } from "./workflow-helpers/codebase-audit.mjs";
import { run as orchestrate } from "./workflow-helpers/orchestrate.mjs";
import { run as rebaseAgent } from "./workflow-helpers/rebase-agent.mjs";
import { run as ciFixer } from "./workflow-helpers/ci-fixer.mjs";
import { run as codeReviewer } from "./workflow-helpers/code-reviewer.mjs";
import { run as shipIssue } from "./workflow-helpers/ship-issue.mjs";
import { run as modelTier } from "./workflow-helpers/model-tier.mjs";

// The extractor's own negative self-check runs first: if the slice boundary has
// drifted, every area below is extracting garbage, and this says so directly
// rather than leaving a wall of confusing downstream failures.
const AREAS = [
  ["extractor self-check", selfCheck],
  ["codebase-audit", codebaseAudit],
  ["orchestrate", orchestrate],
  ["rebase-agent", rebaseAgent],
  ["ci-fixer", ciFixer],
  ["code-reviewer", codeReviewer],
  ["ship-issue", shipIssue],
  ["model-tier", modelTier],
];

for (const [name, run] of AREAS) {
  // setArea makes every assertion failure inside run() carry its area name.
  // Many helper names repeat across harnesses, so an unattributed message like
  // "sanitize: strips newlines" would not say which file to open.
  setArea(name);
  try {
    run();
  } catch (err) {
    // Attribute the throw to its area and keep going. `err?.stack || err` keeps
    // a non-Error throw (a bare string) readable instead of "[object Object]".
    recordFailure(`threw outside an assertion — ${err?.stack || err}`);
  }
}
setArea("");

report(`workflow.js pure helpers (${AREAS.length} areas)`);
