
// Stop spawning further reviewers once the shared budget gets this close to
// empty, so a partial cycle still returns classified findings instead of
// throwing mid-barrier. Matches the ci-fixer / code-reviewer harnesses.
const BUDGET_FLOOR = 40_000

// Reserve for the TERMINAL single-agent stages (comment-triage, judge). These
// are bare `await agent(...)` calls, not fan-out barriers: a
// throw here is NOT caught by parallel()/pipeline() and would kill the whole
// script, discarding every finding the cycle already paid for. `tailAgent`
// below routes an exhausted-budget tail to the SAME null-fallback a barrier
// thunk already gets, so a partial cycle still returns its classified findings.
// A tail stage costs far less than a fan-out barrier, so a smaller reserve than
// BUDGET_FLOOR suffices. DISTINCT identifier on purpose — the BUDGET_FLOOR
// house-value lint (tests/lint-skills-agents.sh) greps `const BUDGET_FLOOR = …`
// and must never match this.
const TAIL_FLOOR = 8_000

// Run a terminal single-agent stage without letting it throw the run away.
// Returns the agent result, or `null` when the budget is too low to spend
// (pre-check) OR the call throws anyway (a ceiling overshoot mid-tail) — both
// degrade to the caller's existing `if (!result)` fallback. `fn` is a thunk so
// the agent() call is only made when we decide to spend.
async function tailAgent(fn, label) {
  if (reviewBudget.total && reviewBudget.remaining() < TAIL_FLOOR) {
    log(`budget low — skipping ${label} (degrading to fallback)`)
    return null
  }
  try {
    return await fn()
  } catch (e) {
    log(`${label} threw (${e && e.message ? e.message : e}) — degrading to fallback`)
    return null
  }
}

// Run a LEADING single-agent stage without letting it throw the run away — the
// manifest's analog of `tailAgent` (#646). Two differences from that helper, both
// deliberate:
//
//   1. No budget pre-check. There is nothing to conserve ahead of the cycle's
//      first agent, and skipping the manifest for budget would kill the cycle
//      just as surely as a crash.
//   2. A DISCRIMINATED result rather than a bare null, because the caller must
//      tell the two failures apart to report which one fired (AC3). A null-return
//      and a throw are the same void to the harness but not to the person reading
//      the log: `agent()` returns null on a terminal API error and THROWS on
//      StructuredOutput retry-cap exhaustion.
//
// Why this exists at all: #616 guarded the manifest with `if (!manifest)`, which
// only runs when `agent()` RETURNS. The failure actually observed — twice — is a
// retry-cap throw (`StructuredOutput retry cap (5) exceeded`, the payload correct
// on all five attempts but wrapped in a `$PARAMETER_VALUE` envelope). That throw
// propagated out of the script: the whole workflow exited `failed`, `emptyResult`
// was never constructed, `no_review_signal` was never set, and the convergence
// helper's C0b rule never saw the cycle — so the slot was charged exactly as
// before #616's fix, and the C0-attempt-cap accounting never counted it either.
//
// Lives in the pure prefix (above ORCH_BOUNDARY) rather than as an inline
// try/catch at the call site so the throw path is genuinely unit-testable. The
// call site is past the boundary and can only be pinned structurally (#636); a
// test that can only regex the source cannot fail when the catch is removed,
// which is precisely the mutation AC4 requires to be caught.
//
// `fn` is a thunk so the agent() call is made inside the try — passing a live
// promise would let a synchronous throw in the prompt builder escape.
async function attempt(fn, label) {
  try {
    const value = await fn()
    // A null return is a failure too — same void, different cause. Reported
    // separately (`threw: false`) rather than folded into one flag.
    if (!value) return { ok: false, threw: false }
    return { ok: true, value }
  } catch (e) {
    log(`${label} threw (${e && e.message ? e.message : e}) — reporting the cycle instead of crashing`)
    return { ok: false, threw: true, error: e }
  }
}

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
