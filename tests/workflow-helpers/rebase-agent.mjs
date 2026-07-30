// rebase-agent — workflow.js pure-helper tests (issue #564 split).
//
// Pure-helper coverage for the rebase-agent workflow.js harness.
//
// Covers verifyExitReason (#259). Note that rebase-agent's safeRef / field are
// byte-identical to orchestrate's and are tested against BOTH sources in
// orchestrate.mjs, so they are deliberately not repeated here.
//
// Extracted verbatim from tests/validate-workflow-helpers.mjs. Assertions are
// collect-all (they record, never throw), so a failure here does not mask any
// sibling area — see tests/lib/mjs-assert.mjs.

import { eq } from "../lib/mjs-assert.mjs";
import { extractHelpers, REBASE } from "../lib/extract-helpers.mjs";

export function run() {
  // =============================================================================
  // rebase-agent — verifyExitReason (#259)
  // =============================================================================
  {
    const { verifyExitReason } = extractHelpers(REBASE, ["verifyExitReason"]);
    eq(
      verifyExitReason({ summary: "markers remain" }, false),
      "markers remain",
      "verifyExitReason: a real verdict's summary always wins",
    );
    eq(
      verifyExitReason({ summary: "markers remain" }, true),
      "markers remain",
      "verifyExitReason: a real verdict wins even if the budget later gated",
    );
    eq(
      verifyExitReason(null, true),
      "budget exhausted before verify",
      "verifyExitReason: budget-gated with no verdict reports the budget reason",
    );
    eq(
      verifyExitReason(null, false),
      "regen/re-test failed",
      "verifyExitReason: a null agent verdict (not budget-gated) reports the regen reason",
    );
  }
}
