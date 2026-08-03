// Shared collect-all assertion surface for the .mjs validators (issue #564).
//
// Extracted from tests/validate-workflow-helpers.mjs when that 3,351-line file
// was split into per-harness modules under tests/workflow-helpers/. The whole
// point of the split is that a failure in one area is reported WITHOUT masking
// its siblings, and that property lives here: every assertion records into ONE
// module-level `failures` array and NEVER throws, so the entry point can run
// every area and report the union at the end.
//
// A per-area `process.exit` (or a throwing assertion) would lose every later
// area's results — the exact silent-drop the split must not introduce. ES module
// instances are singletons per specifier, so all areas importing this file share
// the same array and counter; the entry point reads them once via report().
//
// Zero external dependencies (node built-ins only), like the validators that
// consume it — portable to host + container, no install step.

const failures = [];
let assertions = 0;

// The area currently executing, set by the entry point around each run(). Every
// recorded failure is prefixed with it, so a message that reads identically in
// two areas (many do — the harnesses share helper names) still names the file to
// open. Empty outside a run(), in which case no prefix is added.
let currentArea = "";

/** setArea(name) — entry-point bookkeeping; see `currentArea` above. */
export function setArea(name) {
  currentArea = name || "";
}

function push(msg) {
  failures.push(currentArea ? `[${currentArea}] ${msg}` : msg);
}

/** ok(cond, msg) — record a failure when `cond` is falsy. Never throws. */
export function ok(cond, msg) {
  assertions += 1;
  if (!cond) push(msg);
}

/** eq(actual, expected, msg) — strict-equality assertion with a value diff. */
export function eq(actual, expected, msg) {
  ok(
    actual === expected,
    `${msg} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

// resolves(promise, msg) — await a promise that must RESOLVE, recording a
// failure instead of propagating if it rejects. Returns the resolved value, or
// `undefined` on rejection.
//
// Why this exists (#646): the guards under test convert a thrown agent call into
// a returned failure record, so the natural test is "await it and inspect the
// result". But if the guard regresses, that await REJECTS — and a bare `await`
// inside an area's run() escapes every assertion, aborts the rest of the block,
// and is recorded by the entry point as one opaque "threw outside an assertion".
// Measured while writing the mutation check: removing the catch masked ~25
// sibling assertions in the same block. That is the collect-all property the
// #564 split exists to protect, so the rejection is caught HERE and attributed
// like any other failure.
//
// Callers should use `?.` on the returned value — it is undefined on rejection,
// and a bare field access would re-introduce the throw this helper prevents.
export async function resolves(promise, msg) {
  assertions += 1;
  try {
    return await promise;
  } catch (err) {
    push(`${msg} — expected it to resolve, but it rejected: ${err?.message || err}`);
    return undefined;
  }
}

/** throws(fn, msg) — assert `fn` throws. The throw is caught, never propagated. */
export function throws(fn, msg) {
  assertions += 1;
  try {
    fn();
    push(`${msg} — expected a throw, but none occurred`);
  } catch {
    /* expected */
  }
}

// Record a failure directly, for the entry point's try/catch around each area.
// An area that throws OUTSIDE an assertion (an extractHelpers TDZ blow-up, a
// bad slice boundary) would otherwise abort the whole run; the entry catches it
// and funnels it here so the remaining areas still execute and still report.
export function recordFailure(msg) {
  push(msg);
}

/** Current counts — for the entry point's own bookkeeping and for tests. */
export function counts() {
  return { assertions, failures: failures.length };
}

// Print the aggregated result and exit. `label` names the suite in the success
// line. Exits 1 when anything failed, listing every failure across every area.
export function report(label) {
  if (failures.length > 0) {
    console.error(`✗ ${failures.length} ${label} assertion(s) failed:`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log(`✓ ${label}: ${assertions} assertions passed`);
}
