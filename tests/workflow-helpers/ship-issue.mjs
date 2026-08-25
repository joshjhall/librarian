// ship-issue — workflow.js pure-helper tests (issue #564 split, #712 sub-split).
//
// Pure-helper coverage for the ship-issue workflow.js harness.
//
// Covers refOf/emptyResult/computeClean/sameCommentId, the #492 re-review
// narrowing selector, the #260 TDZ regression, #267's diffSection, and the
// #553/#556/#557 review-cost surface (reviewBudget, exploration bounds, the
// off-by-default ceiling, pre-scan candidate handoff, conventions digest).
//
// THIS FILE IS A THIN DISPATCHER (issue #712). It was one 2,142-line
// `export async function run()` — 1,374 production LOC, past the review lens's
// 800 `high` threshold, and the largest single file in the repo's .mjs corpus.
// The assertions now live in per-area modules under tests/workflow-helpers/
// ship-issue/, following the same thin-entry-point shape #564 gave the shell
// suites and gave this file's own parent (tests/validate-workflow-helpers.mjs).
//
// The path did NOT move: validate-workflow-helpers.mjs still imports `run` from
// here, so its AREAS list is untouched and every failure still reports under the
// single "ship-issue" area name its setArea() stamps.
//
// Two properties this dispatcher is responsible for, mirroring its parent:
//
//   1. NO area can mask its siblings. Assertions are collect-all by design, but
//      an area can still throw OUTSIDE an assertion — an extractHelpers TDZ
//      blow-up, a drifted slice boundary. Each run() is therefore called inside
//      try/catch: the throw is recorded as a failure naming its module, and the
//      remaining areas still execute.
//
//   2. NO area can be silently dropped. AREAS below is an EXPLICIT ordered list,
//      not a glob, for the reason tests/lib/fragments.sh states for the shell
//      suites: a module nobody dispatches contributes zero assertions and the
//      suite still reports green with a smaller total nobody notices — strictly
//      worse than the monolith, where a case could only vanish in a visible
//      diff. assertAreasRegistered() closes the hole in BOTH directions against
//      what is actually on disk (see below).

import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { recordFailure } from "../lib/mjs-assert.mjs";

import { run as pureHelpers } from "./ship-issue/01-pure-helpers.mjs";
import { run as judgeDisposition } from "./ship-issue/02-judge-disposition.mjs";
import { run as narrowingSelector } from "./ship-issue/03-narrowing-selector.mjs";
import { run as tdzAndDiff } from "./ship-issue/04-tdz-and-diff.mjs";
import { run as reviewBudget } from "./ship-issue/05-review-budget.mjs";
import { run as preScanConventions } from "./ship-issue/06-prescan-conventions.mjs";
import { run as argValidation } from "./ship-issue/07-arg-validation.mjs";
import { run as manifestFailure } from "./ship-issue/08-manifest-failure.mjs";

const AREA_DIR = join(dirname(fileURLToPath(import.meta.url)), "ship-issue");

// [module filename, run fn] — the filename is load-bearing, not decorative: it
// is what assertAreasRegistered diffs against the directory listing.
const AREAS = [
  ["01-pure-helpers.mjs", pureHelpers],
  ["02-judge-disposition.mjs", judgeDisposition],
  ["03-narrowing-selector.mjs", narrowingSelector],
  ["04-tdz-and-diff.mjs", tdzAndDiff],
  ["05-review-budget.mjs", reviewBudget],
  ["06-prescan-conventions.mjs", preScanConventions],
  ["07-arg-validation.mjs", argValidation],
  ["08-manifest-failure.mjs", manifestFailure],
];

// Fail when the declared list and the directory disagree, in either direction.
// An UNLISTED file on disk is the silent-drop case (#596's "test defined but
// never registered", reached by the .mjs route); a LISTED file that is missing
// would already have thrown at import, but is checked anyway so a future switch
// to lazy import cannot reopen the hole quietly.
function assertAreasRegistered() {
  const onDisk = readdirSync(AREA_DIR)
    .filter((f) => f.endsWith(".mjs"))
    .sort();
  const declared = AREAS.map(([name]) => name).sort();

  for (const f of onDisk) {
    if (!declared.includes(f)) {
      recordFailure(
        `ship-issue area module ${f} exists on disk but is not in AREAS — ` +
          "its assertions never run (add it to the list in ship-issue.mjs)",
      );
    }
  }
  for (const f of declared) {
    if (!onDisk.includes(f)) {
      recordFailure(`ship-issue area module ${f} is declared in AREAS but missing from ${AREA_DIR}`);
    }
  }
}

// async because the #646 area exercises `attempt`, an async guard. The entry
// point awaits every run(), so a synchronous area is unaffected.
export async function run() {
  assertAreasRegistered();

  for (const [name, area] of AREAS) {
    try {
      // AWAITED for the reason validate-workflow-helpers.mjs documents: an area
      // testing an async helper returns a promise, and calling it bare would let
      // its assertions land after report() had already printed.
      await area();
    } catch (err) {
      recordFailure(
        `ship-issue/${name} threw outside an assertion — ${err?.stack || err}`,
      );
    }
  }
}
