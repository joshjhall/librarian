// ship-issue area — review cost surface — reviewBudget, CYCLE_TOKEN_CEILING, MAX_CYCLES, SCOPE_DISCIPLINE
//
// Split out of tests/workflow-helpers/ship-issue.mjs (#712): the file had grown
// to 1374 production LOC as a single `export async function run()`, past the
// review lens's 800 `high` threshold. Content moved VERBATIM — only the
// indentation and the import depth changed.
//
// Covers #553/#556/#557: the off-by-default ceiling and the exploration bounds.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
// =============================================================================
// ship-issue — reviewBudget: the caller-supplied per-cycle token ceiling (#553)
// =============================================================================
// Every budget gate in the harness is guarded on `budget.total`, which the
// Workflow runtime populates ONLY from a user "+500k"-style turn directive. In a
// golem run there is no such directive, so `total` is null and BUDGET_FLOOR /
// TAIL_FLOOR never fire. `reviewBudget` restores a bound by deriving one from
// `args.tokenCeiling` and `budget.spent()` (which works even when `total` is
// null), while deferring to a runtime-armed budget when one exists.
{
  const extractBudget = (args, budgetStub) =>
    extractHelpers(SHIP, ["reviewBudget", "CYCLE_TOKEN_CEILING"], args, budgetStub).reviewBudget;

  const noRuntimeBudget = (spent = 0) => ({
    total: null,
    spent: () => spent,
    remaining: () => Infinity,
  });

  // No ceiling armed and no runtime budget ⇒ unbounded, exactly as before #553.
  // This is the compatibility guarantee: omitting tokenCeiling changes nothing.
  const unbounded = extractBudget({ cycle: 1 }, noRuntimeBudget());
  eq(unbounded.total, null, "reviewBudget: no ceiling + no runtime budget ⇒ total null (unbounded)");
  eq(unbounded.remaining(), Infinity, "reviewBudget: unbounded remaining() is Infinity");

  // Ceiling armed, nothing spent yet ⇒ the full ceiling is available and `total`
  // is non-null, which is what actually ARMS every `budget.total && …` gate.
  const armed = extractBudget({ cycle: 1, tokenCeiling: 200000 }, noRuntimeBudget(0));
  eq(armed.total, 200000, "reviewBudget: tokenCeiling sets a non-null total (arms the gates)");
  eq(armed.remaining(), 200000, "reviewBudget: nothing spent ⇒ full ceiling remaining");

  // Spend is measured as a DELTA from script start, not absolute. A cycle that
  // begins after 500k was already spent this turn must still get its full
  // ceiling — otherwise cycle 2 of a 3-cycle loop would start pre-exhausted.
  const midTurn = extractBudget({ cycle: 2, tokenCeiling: 200000 }, noRuntimeBudget(500000));
  eq(midTurn.remaining(), 200000, "reviewBudget: ceiling is per-cycle — prior turn spend does not count against it");
  eq(midTurn.spent(), 0, "reviewBudget: spent() is a delta from script start");

  // Draining the ceiling: remaining() falls, and floors below it. A drained
  // ceiling must read 0, never negative — a negative would still compare
  // `< BUDGET_FLOOR` correctly but would misreport in logs.
  // NOTE: the baseline is captured at extraction time, so `live` must start at
  // the value it holds when extractBudget runs; subsequent moves are the spend.
  let live = 0;
  const draining = extractBudget(
    { cycle: 1, tokenCeiling: 200000 },
    { total: null, spent: () => live, remaining: () => Infinity },
  );
  live = 1000;
  eq(draining.remaining(), 199000, "reviewBudget: remaining() tracks spend");
  live = 199999;
  eq(draining.remaining(), 1, "reviewBudget: remaining() approaches zero as spend nears the ceiling");
  live = 250000;
  eq(draining.remaining(), 0, "reviewBudget: an overshot ceiling floors at 0, never negative");

  // A runtime-armed budget WINS over the caller ceiling: the runtime enforces
  // its own by throwing, so the harness must not paper over it with a larger
  // caller value and spawn agents the runtime will kill.
  const runtimeArmed = extractBudget(
    { cycle: 1, tokenCeiling: 999999 },
    { total: 50000, spent: () => 10000, remaining: () => 40000 },
  );
  eq(runtimeArmed.total, 50000, "reviewBudget: a runtime-armed budget takes precedence over the caller ceiling");
  eq(runtimeArmed.remaining(), 40000, "reviewBudget: runtime-armed remaining() defers to the runtime");

  // Malformed ceilings fail SAFE (unbounded, the historical default) rather than
  // arming a nonsense bound that silently truncates every cycle to nothing.
  for (const bad of [0, -1, 1.5, "200000", null, undefined, NaN]) {
    const b = extractBudget({ cycle: 1, tokenCeiling: bad }, noRuntimeBudget());
    eq(b.total, null, `reviewBudget: tokenCeiling=${JSON.stringify(bad)} is rejected (stays unbounded)`);
  }
}

// =============================================================================
// ship-issue — the maxCycles default mirrors REVIEW_MAX_CYCLES (#620)
// =============================================================================
// MAX_CYCLES feeds the harness's own `review cycle N/M` log line. It is
// informational — the SKILL owns the real loop and review-convergence.sh owns
// the cap — so a stale value misreports progress rather than changing behavior,
// and nothing else would go red if it drifted. #596 raised REVIEW_MAX_CYCLES'
// default 3 -> 5 and #617 mirrored it here; this pins that mirror so an
// accidental revert, or drift from review-convergence.sh's default, fails.
//
// Three rows deliberately, not just the default: asserting `=== 5` alone would
// ALSO pass against a hardcoded `const MAX_CYCLES = 5` that ignores `args`
// entirely, so the honored-override row is what proves the Number.isInteger
// branch is live. The third row pins the non-integer fallback.
{
  const { MAX_CYCLES: fallback } = extractHelpers(SHIP, ["MAX_CYCLES"]);
  eq(fallback, 5, "ship-issue: an omitted args.maxCycles defaults to 5 (mirrors REVIEW_MAX_CYCLES, #620)");

  const { MAX_CYCLES: explicit } = extractHelpers(SHIP, ["MAX_CYCLES"], { maxCycles: 3 });
  eq(explicit, 3, "ship-issue: an explicit integer args.maxCycles is honored (the default is not hardcoded)");

  const { MAX_CYCLES: coerced } = extractHelpers(SHIP, ["MAX_CYCLES"], { maxCycles: "7" });
  eq(coerced, 5, "ship-issue: a non-integer args.maxCycles falls back to the default rather than being coerced");

  // Where the guard STOPS. Unlike tokenCeiling above — whose malformed values
  // all fail safe to unbounded — Number.isInteger(0) and Number.isInteger(-1)
  // are both true, so a 0 or negative maxCycles passes through verbatim into
  // the `review cycle N/M` line. That is tolerable precisely because the value
  // is informational (review-convergence.sh validates the real cap and rejects
  // < 1), but it is a genuine asymmetry between two neighbouring args, so pin
  // it rather than leave the boundary undocumented and drifting.
  for (const [bad, want] of [
    [0, 0],
    [-1, -1],
    [1.5, 5],
    [NaN, 5],
    [null, 5],
  ]) {
    const { MAX_CYCLES: got } = extractHelpers(SHIP, ["MAX_CYCLES"], { maxCycles: bad });
    eq(got, want, `ship-issue: maxCycles=${JSON.stringify(bad)} yields ${want} (integer check, not a range check)`);
  }
}

// =============================================================================
// ship-issue — exploration bounds are attached to every reviewer prompt (#553)
// =============================================================================
// The scope-discipline text is what bounds in-agent repo exploration (measured:
// one `security` agent spent 254 turns / 115 Bash calls on a 2-file diff). It is
// only effective if EVERY reviewer prompt carries it — a dimension that misses it
// is the one that will range over the repo.
{
  const src = harnessSource(SHIP);
  ok(/const SCOPE_DISCIPLINE\s*=/.test(src), "ship-issue: SCOPE_DISCIPLINE is defined");
  for (const builder of ["reusedReviewerPrompt", "newReviewerPrompt"]) {
    const start = src.indexOf(`const ${builder} =`);
    ok(start !== -1, `ship-issue: ${builder} exists`);
    // The builder body runs to the next top-level `const ` declaration.
    const end = src.indexOf("\nconst ", start + 1);
    const body = src.slice(start, end === -1 ? src.length : end);
    ok(body.includes("SCOPE_DISCIPLINE"), `ship-issue: ${builder} includes SCOPE_DISCIPLINE (#553)`);
  }
}
}
