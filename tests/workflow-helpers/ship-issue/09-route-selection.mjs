// ship-issue area — the #550 doc/config-only review routing
//
// The routing DECISION lives in scripts/review-route.sh (tested by
// tests/validate-review-route.sh); this area covers what the harness does with
// the verdict once it arrives as `args.reviewRoute`.
//
// THE PROPERTY THAT MATTERS MOST IS NEGATIVE. A routed cycle is allowed to
// return `clean: true`, and `clean` is half the merge invariant. That is only
// sound because routing is COMPLETE-BY-DESIGN rather than TRUNCATION — which in
// code means the cheap path must leave `dimensionsSkipped` empty and
// `budgetExhausted` false. If a future edit routed dimensions away by pushing
// them into `dimensionsSkipped` (the obvious-looking implementation), every
// routed cycle would silently become partial, `clean` would be forced false,
// and every doc-only PR would run to the cycle cap and dead-end. So those two
// fields are asserted explicitly, not incidentally.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
  const { selectReviewDimensions, REUSED_DIMENSIONS, NEW_DIMENSIONS } = extractHelpers(
    SHIP,
    ["selectReviewDimensions", "REUSED_DIMENSIONS", "NEW_DIMENSIONS"],
    { cycle: 1, phase: "pre-pr", files: ["README.md"] },
  );

  const budgetOff = { total: null, remaining: () => Infinity, spent: () => 0 };
  const fullDiff = "FULL-DIFF";

  // A doc-only cycle: cycle 1, no delta args (so narrowing is off and the route
  // is the only thing that can drop a dimension). Keeping narrowing out of the
  // fixture is deliberate — it isolates the routing behavior, so a failure here
  // can only be about the route.
  const call = (opts) =>
    selectReviewDimensions({
      cycle: 1,
      fullDiff,
      deltaDiff: "",
      deltaFiles: [],
      priorBlocking: [],
      manifest: { classifications: [{ file: "README.md", types: ["docs"] }] },
      budget: budgetOff,
      budgetFloor: 40000,
      reusedDimensions: REUSED_DIMENSIONS,
      newDimensions: NEW_DIMENSIONS,
      ...opts,
    });

  // --- The cheap route ------------------------------------------------------

  const cheap = call({ route: "cheap" });
  const cheapNames = cheap.entries.map((e) => e.dim.name).sort();

  eq(
    JSON.stringify(cheapNames),
    JSON.stringify(["decomposition", "scope-drift"]),
    "route=cheap: exactly the dimensions whose DIMENSION_RELEVANT_TYPES entry claims `docs` (decomposition), plus scope-drift",
  );

  // The derived-not-hardcoded property, asserted directly. `decomposition` is on
  // the cheap path BECAUSE its normative entry lists `docs` — not because a
  // second list somewhere names it. Five separate blocking findings on this
  // feature were places where a hand-maintained list disagreed with that table;
  // deriving is what removes the class.
  ok(
    cheapNames.includes("decomposition"),
    "route=cheap: decomposition SURVIVES — its DIMENSION_RELEVANT_TYPES entry lists `docs`, and markdown progressive-disclosure findings fire on exactly these diffs (#589/#695)",
  );

  // Stated as its own assertion rather than left implicit in the list above:
  // scope-drift's survival is the issue's explicit requirement (it is the one
  // dimension reading the issue's ACs, and a doc-only diff can still fail an
  // AC), so it deserves a failure message that says why.
  ok(
    cheapNames.includes("scope-drift"),
    "route=cheap: scope-drift SURVIVES routing — it is the AC-completeness lens, and a doc-only diff can still miss an acceptance criterion",
  );

  for (const dropped of ["security", "correctness", "tests"]) {
    ok(
      !cheapNames.includes(dropped),
      `route=cheap: the ${dropped} dimension is dropped — its DIMENSION_RELEVANT_TYPES entry does not claim \`docs\``,
    );
  }

  ok(
    cheap.entries.every((e) => e.diff === fullDiff),
    "route=cheap: scope-drift still reads the FULL diff (whole-change lens, unchanged by routing)",
  );

  // --- The clean-safety property (the reason this file exists) --------------
  //
  // These two are what separate "complete-by-design" from "truncated". Both are
  // asserted on the CHEAP result, where a wrong implementation would populate
  // them — asserting on the full result would be a tautology.

  eq(
    cheap.dimensionsSkipped.length,
    0,
    "route=cheap: dimensionsSkipped stays EMPTY — a routed-around dimension had nothing to review, which is not the same as a dimension that should have run and did not",
  );
  eq(
    cheap.budgetExhausted,
    false,
    "route=cheap: budgetExhausted stays FALSE — routing must not mark the cycle partial, or computeClean would force clean=false and every doc-only PR would run to the cycle cap and dead-end",
  );
  eq(cheap.cheap, true, "route=cheap: the selector reports the route back to the caller");

  // --- The full route is unchanged -----------------------------------------

  const full = call({ route: "full" });
  const fullNames = full.entries.map((e) => e.dim.name).sort();
  eq(
    JSON.stringify(fullNames),
    JSON.stringify(["correctness", "decomposition", "scope-drift", "security", "tests"]),
    "route=full: every dimension runs, exactly as before #550 (five post-#551)",
  );
  eq(full.cheap, false, "route=full: not reported as cheap");

  // Absent route ⇒ full. This is the back-compatibility guarantee: every call
  // site and test predating #550 passes no `route` at all and must be
  // byte-identical to before.
  const noRoute = call({});
  eq(
    JSON.stringify(noRoute.entries.map((e) => e.dim.name).sort()),
    JSON.stringify(fullNames),
    "route absent: defaults to the full fan-out (additive, default-off — pre-#550 callers unchanged)",
  );
  eq(noRoute.cheap, false, "route absent: not cheap");

  // --- Fail-safe on a malformed route --------------------------------------
  //
  // Each fixture is a value a PERMISSIVE implementation would accept as cheap
  // (truthy, or cheap-adjacent), so a `route !== 'full'` style check — the
  // natural wrong spelling — would route them cheap and fail here. Asserting on
  // a disjoint value like "banana" alone would be far weaker.
  for (const bogus of ["Cheap", "CHEAP", "cheap ", " cheap", "cheep", true, 1, {}, ["cheap"], null, undefined]) {
    const r = call({ route: bogus });
    eq(
      r.entries.length,
      5,
      `route=${JSON.stringify(bogus)}: a malformed route falls back to the FULL fan-out (fail safe — anything but the exact string 'cheap' must widen the review, never narrow it)`,
    );
  }

  // --- The args-level parse ------------------------------------------------
  //
  // The loop above passes `route` straight to the selector, which exercises the
  // SELECTOR's handling but not the `args.reviewRoute` parse that feeds it.
  // Those are two separate places a permissive check could be written, and a
  // mutation round proved it: rewriting the parse as
  // `args.reviewRoute && args.reviewRoute !== 'full' ? 'cheap' : 'full'`
  // survived every assertion above. So drive the real const through
  // extractHelpers with a real `args`.
  const routeFromArgs = (argsObj) =>
    extractHelpers(SHIP, ["reviewRoute"], argsObj).reviewRoute;

  eq(routeFromArgs({ reviewRoute: "cheap" }), "cheap", "args.reviewRoute: the exact string 'cheap' is honored");
  eq(routeFromArgs({ reviewRoute: "full" }), "full", "args.reviewRoute: 'full' is full");
  eq(routeFromArgs({}), "full", "args.reviewRoute: absent ⇒ full (additive, default-off)");
  eq(routeFromArgs(null), "full", "args.reviewRoute: a null args object ⇒ full");

  // The divergent fixtures — every one is truthy and not 'full', so the
  // permissive spelling routes them CHEAP and this block goes red.
  for (const bogus of ["Cheap", "CHEAP", "cheap ", " cheap", "cheep", "auto", true, 1, {}, ["cheap"]]) {
    eq(
      routeFromArgs({ reviewRoute: bogus }),
      "full",
      `args.reviewRoute=${JSON.stringify(bogus)}: parsed as FULL — the allowlist is the exact string 'cheap' alone, so a typo or a wrong type widens the review instead of silently skipping the security and correctness dimensions`,
    );
  }
}
