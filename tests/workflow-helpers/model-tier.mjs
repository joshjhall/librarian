// model-tier — workflow.js pure-helper tests (issue #564 split).
//
// Judge/verify model tier is pinned at the three harness call sites (#526).
//
// Cross-harness by nature (ship-issue, code-reviewer, codebase-audit), so this
// lives in its own area module rather than being duplicated into three.
//
// Extracted verbatim from tests/validate-workflow-helpers.mjs. Assertions are
// collect-all (they record, never throw), so a failure here does not mask any
// sibling area — see tests/lib/mjs-assert.mjs.

import { ok } from "../lib/mjs-assert.mjs";
import { harnessSource, CA, REVIEW, SHIP } from "../lib/extract-helpers.mjs";

export function run() {
  // =============================================================================
  // Judge/verify model tier is pinned at the three harness call sites (#526)
  // =============================================================================
  // These `model:` literals live in the orchestration body, PAST the
  // ORCH_BOUNDARY that extractHelpers() slices at, so no pure-helper test can
  // reach them; lint-skills-agents.sh only validates the `model:` frontmatter of
  // *.md agent files, never a string literal inside a workflow.js. That left the
  // tier unpinned by any gate — a revert to 'fable' or a typo'd model string at
  // any of the three gates would pass `just test` and only surface as a surprise
  // on the bill. Assert against the raw source rather than an evaluated helper.
  //
  // Scope each assertion to the OPTIONS BLOCK of the labeled call, not the whole
  // file: a whole-file substring search passes only while each file happens to
  // hold exactly one `model:` literal. It would miss a real regression (this gate
  // dropped to 'sonnet' while some other call in the same file reads 'opus') and
  // would false-fail a legitimate future `fable` stage elsewhere in the file —
  // patterns.md still permits fable with a measured result.
  {
    const TIER_SITES = [
      { path: SHIP, stage: "judge" },
      { path: REVIEW, stage: "rescore" },
      { path: CA, stage: "verify" },
    ];
    for (const { path, stage } of TIER_SITES) {
      const src = harnessSource(path);
      const marker = `label: '${stage}'`;
      const start = src.indexOf(marker);
      ok(start !== -1, `${stage} (${path}): labeled agent() call is present`);
      if (start === -1) continue;
      ok(
        src.indexOf(marker, start + marker.length) === -1,
        `${stage} (${path}): label is unique, so the slice below is unambiguous`,
      );
      // The options object ends at its closing brace — the first `}` at the call's
      // indentation. `}),` is the agent({...}) close in all three harnesses.
      const end = src.indexOf("}),", start);
      ok(end !== -1, `${stage} (${path}): options block terminates`);
      const optionsBlock = src.slice(start, end);
      ok(
        optionsBlock.includes("model: 'opus'"),
        `${stage} (${path}): judge/verify gate pins model: 'opus' (#526)`,
      );
      ok(
        !optionsBlock.includes("model: 'fable'"),
        `${stage} (${path}): judge/verify gate is not on the fable tier (#526)`,
      );
    }
  }
}
