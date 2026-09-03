
// ---------------------------------------------------------------------------
// `BUDGET_FLOOR`, `TAIL_FLOOR`, `tailAgent`, and `attempt` now come from the
// shared prelude (#586) — see 15-prelude.js, generated from
// plugins/lib/prelude.js. This file keeps the notes SPECIFIC to this harness:
//
//   - The TERMINAL stages guarded by `tailAgent` here are comment-triage and the
//     judge. They are bare `await agent(...)` calls, not fan-out barriers, so a
//     throw is NOT caught by parallel()/pipeline() and would kill the whole
//     script, discarding every finding the cycle already paid for.
//
//   - `attempt` exists because #616 guarded the manifest with `if (!manifest)`,
//     which only runs when `agent()` RETURNS. The failure actually observed —
//     twice — is a retry-cap throw (`StructuredOutput retry cap (5) exceeded`,
//     the payload correct on all five attempts but wrapped in a
//     `$PARAMETER_VALUE` envelope). That throw propagated out of the script: the
//     whole workflow exited `failed`, `emptyResult` was never constructed,
//     `no_review_signal` was never set, and the convergence helper's C0b rule
//     never saw the cycle — so the slot was charged exactly as before #616's
//     fix, and the C0-attempt-cap accounting never counted it either.
//
//   - Both live in the pure prefix (above ORCH_BOUNDARY) rather than as inline
//     try/catch at the call sites so the throw paths are genuinely
//     unit-testable. A call site past the boundary can only be pinned
//     structurally (#636), and a test that can only regex the source cannot fail
//     when the catch is removed — precisely the mutation #646 AC4 requires to be
//     caught.
//
//   - This harness's `budgetLow` / `FALLBACK_NOUN` seams live in
//     14-prelude-seams.js, which must load BEFORE the prelude fragment.
// ---------------------------------------------------------------------------

// The reason string for a failed manifest, naming WHICH failure fired (#646
// AC3). A pure function rather than an inline ternary at the call site for the
// same reason `attempt` is: the call site is past ORCH_BOUNDARY, so an inline
// version could only be regex-asserted, and a regex cannot tell that the two
// branches produce DIFFERENT strings — which is the whole property that saves
// the next person a transcript read.
//
// The error message is `sanitize`d: it is attacker-influenced in the general
// case (it can quote model output) and this string is log()'d, so a smuggled
// newline must not start what looks like a new log line.
const manifestFailureNote = (threw, error) =>
  threw
    ? `manifest step failed (agent threw: ${sanitize(error && error.message ? error.message : error, 200)}) — nothing to review this cycle`
    : 'manifest step failed (agent returned no result) — nothing to review this cycle'
