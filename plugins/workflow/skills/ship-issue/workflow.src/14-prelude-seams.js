
// ---------------------------------------------------------------------------
// Per-harness seams the shared prelude reads (#586).
//
// ORDER IS LOAD-BEARING, IN BOTH DIRECTIONS:
//   - AFTER 10-args-contract.js, because `budgetLow` closes over `reviewBudget`
//     (defined there). Hoisting saves the function itself, not the binding it
//     reads.
//   - BEFORE 15-prelude.js, because `FALLBACK_NOUN` is a `const`. The prelude's
//     `attempt` reads it, so a prelude placed above this file is a
//     temporal-dead-zone throw the moment `attempt` runs.
// The manifest encodes both; do not reorder without re-reading that comment.
// ---------------------------------------------------------------------------

// This harness spends against `reviewBudget`, not the raw engine `budget`: a
// cycle's ceiling is per-cycle (#553), measured from SPENT_AT_START rather than
// from the run's origin, so a later cycle is not starved by earlier ones. That
// indirection is precisely why the prelude reads a per-harness predicate instead
// of hardcoding a budget object.
function budgetLow() {
  return !!reviewBudget.total && reviewBudget.remaining() < TAIL_FLOOR
}

// Completes "reporting ${FALLBACK_NOUN} instead of crashing" in the shared
// `attempt`. Per-harness because the noun names THIS harness's degraded output:
// a failed manifest here costs the CYCLE, and the convergence accounting reads
// that wording in the log.
const FALLBACK_NOUN = 'the cycle'
