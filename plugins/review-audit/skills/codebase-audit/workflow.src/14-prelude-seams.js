
// ---------------------------------------------------------------------------
// Per-harness seams the shared prelude reads (#586).
//
// ORDER: must sit BEFORE 15-prelude.js, because `FALLBACK_NOUN` is a `const`
// that the prelude's `attempt` reads — a prelude above it is a temporal-dead-
// zone throw the moment `attempt` runs. `budgetLow` is a function declaration
// and hoists, so it alone would not constrain the order.
//
// This harness is where `budgetLow` originated: #586 adopted its shape as the
// repo-wide seam precisely because it was already the right factoring, so the
// definition below is unchanged from what this file has always had.
// ---------------------------------------------------------------------------

// True when the shared budget is too close to empty to spend on another tail
// stage. Used both by tailAgent (to skip) and by callers deciding whether a null
// tail result was a BUDGET situation (set budget_exhausted) versus a plain agent
// failure (leave budget_exhausted honest, mark scan_failure instead) — this
// harness deliberately keeps those two causes distinct (see the aggregate + scan
// fallbacks).
function budgetLow() {
  return !!budget.total && budget.remaining() < TAIL_FLOOR
}

// Completes "reporting ${FALLBACK_NOUN} instead of crashing" in the shared
// `attempt`. Per-harness because the noun names THIS harness's degraded output:
// a failed map step here means the audit produces nothing to file.
const FALLBACK_NOUN = 'an empty audit'
