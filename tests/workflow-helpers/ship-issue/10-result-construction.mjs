// ship-issue area — the cycle result object's CONSTRUCTION (issue #636)
//
// WHY THIS AREA EXISTS. tests/lib/extract-helpers.mjs slices each harness at
// ORCH_BOUNDARY and evaluates only the pure prefix, so everything past that
// boundary is unreachable by any assertion. In ship-issue that was 440 lines,
// and it included the terminal `return { … }` that assembles every cycle's
// result. The gap was demonstrated, not theorised: on PR #634, replacing the
// `...summarizeJudgeObservations(rawFindings)` spread in that return with
// `tallyBy([], NATURE_VALUES)` — i.e. reporting all-zero #613 distributions on
// every live cycle — left the ENTIRE suite green. It was mutation 11 of 12 and
// the only one not caught.
//
// #636 closed it by extracting `buildResult` into the pure prefix (the shape
// `codebase-audit`'s `finalResult` has used since #262) and reducing both return
// paths to one call each. This area is the coverage that extraction buys.
//
// TWO LAYERS, BOTH REQUIRED — the same pairing workflow-authoring/SKILL.md
// documents for the column-0 dispatch tail:
//
//   (1) BEHAVIOUR. buildResult is extracted and called directly, so every
//       derivation it performs — the by_severity tally, the two #613
//       distributions, `clean` — is exercised against the real code rather than
//       a reimplementation.
//   (2) WIRING. The `return buildResult({…})` call site is itself still past the
//       boundary, so it is pinned literally against the raw source. Without this
//       layer, re-inlining the object literal at the call site would restore the
//       original gap while every assertion in layer (1) kept passing — the
//       helper would still be correct, just no longer used.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, ORCH_BOUNDARY, SHIP } from "../../lib/extract-helpers.mjs";

export function run() {
  const {
    buildResult,
    emptyResult,
    applyJudgeVerdicts,
    NATURE_VALUES,
    DISPOSITION_RULES,
  } = extractHelpers(
    SHIP,
    ["buildResult", "emptyResult", "applyJudgeVerdicts", "NATURE_VALUES", "DISPOSITION_RULES"],
    // `files` seeds scopeFiles, which buildResult reports as files_scanned.
    { cycle: 2, phase: "pr-cycle", files: ["a.js", "b.js", "c.js"] },
  );

  // A finding shaped like the harness's own: `ref` is what applyJudgeVerdicts
  // keys verdicts back by, `severity` is what by_severity counts.
  const mk = (ref, severity) => ({
    file: ref.split("#")[0],
    line_start: 1,
    category: "correctness",
    severity,
    certainty: { level: "HIGH", confidence: 0.9 },
    ref,
  });

  // --- (1a) Every top-level key is always present ---------------------------
  //
  // The contract a reader (and the merge invariant) relies on: a field is never
  // conditionally omitted, because an absent key defaults to false/empty at the
  // reader and would be indistinguishable from a deliberate one. Asserted across
  // variants — including the empty call — so a future field added on only one
  // branch fails here. Modelled on codebase-audit's finalResult coverage.

  const TOP_LEVEL_KEYS = [
    "cycle",
    "phase",
    "scanner",
    "blocking",
    "deferrable",
    "comments_addressed",
    "summary",
    "token_report",
    "budget_exhausted",
    "dimensions_skipped",
    "no_review_signal",
    "clean",
  ];
  const SUMMARY_KEYS = [
    "files_scanned",
    "total_findings",
    "by_disposition",
    "by_severity",
    "by_nature",
    "by_rule",
  ];

  const variants = [
    {},
    { rawFindings: [mk("a.js#0", "high")], blocking: [mk("a.js#0", "high")] },
    { budgetExhausted: true, dimensionsSkipped: ["security"], noReviewSignal: true },
    { commentsAddressed: [{ id: "c1", disposition: "blocking" }], unresolvedLen: 2 },
  ];
  for (const v of variants) {
    const r = buildResult(v);
    for (const k of TOP_LEVEL_KEYS) {
      ok(
        Object.prototype.hasOwnProperty.call(r, k),
        `buildResult: always includes top-level key "${k}" (variant=${JSON.stringify(v).slice(0, 60)}) (#636)`,
      );
    }
    for (const k of SUMMARY_KEYS) {
      ok(
        Object.prototype.hasOwnProperty.call(r?.summary || {}, k),
        `buildResult: summary always includes "${k}" (variant=${JSON.stringify(v).slice(0, 60)}) (#636)`,
      );
    }
  }

  eq(buildResult({}).scanner, "next-issue-review", "buildResult: scanner is fixed (#636)");
  eq(buildResult({}).cycle, 2, "buildResult: cycle comes from the harness config, not the caller (#636)");
  eq(buildResult({}).phase, "pr-cycle", "buildResult: phase comes from the harness config (#636)");
  eq(
    buildResult({}).summary.files_scanned,
    3,
    "buildResult: files_scanned reports the FULL scope (scopeFiles), not the manifest delta (#492)",
  );

  // --- (1b) by_severity is tallied from the findings ------------------------
  //
  // The mutation this must fail: a hardcoded all-zero object. So the fixture
  // mixes severities and asserts a value that only a real count produces.
  {
    const r = buildResult({
      rawFindings: [
        mk("a.js#0", "high"),
        mk("a.js#1", "high"),
        mk("b.js#2", "critical"),
        mk("b.js#3", "low"),
      ],
    });
    eq(r.summary.by_severity.high, 2, "buildResult: by_severity counts repeated severities (#636)");
    eq(r.summary.by_severity.critical, 1, "buildResult: by_severity counts a lone severity (#636)");
    eq(r.summary.by_severity.low, 1, "buildResult: by_severity counts the low bucket (#636)");
    eq(
      r.summary.by_severity.medium,
      0,
      "buildResult: an unseen severity is present at zero, never absent (#636)",
    );
    eq(r.summary.total_findings, 4, "buildResult: total_findings is the raw finding count (#636)");
  }

  // A severity outside the closed FINDING_SCHEMA enum must not become a key of a
  // distribution the operator reads as complete — unlike `nature`, which is
  // LLM-authored and deliberately open (see tallyBy). Pinning the DIFFERENCE
  // between the two, since they sit in the same summary object and a future edit
  // could plausibly unify them the wrong way.
  {
    const r = buildResult({ rawFindings: [mk("a.js#0", "catastrophic"), mk("a.js#1", "high")] });
    ok(
      !Object.prototype.hasOwnProperty.call(r.summary.by_severity, "catastrophic"),
      "buildResult: an off-enum severity does not become a by_severity key (#636)",
    );
    eq(
      Object.values(r.summary.by_severity).reduce((a, b) => a + b, 0),
      1,
      "buildResult: an off-enum severity contributes nothing to the by_severity total (#636)",
    );
    eq(
      r.summary.total_findings,
      2,
      "buildResult: total_findings still counts it, so the shortfall stays readable (#636)",
    );
  }

  // --- (1c) THE #634 MUTATION-11 ASSERTION ----------------------------------
  //
  // The two #613 distributions must be counted FROM the findings that reach
  // buildResult. This is the assertion the whole issue turns on: replacing the
  // `...summarizeJudgeObservations(rawFindings)` spread with `tallyBy([], …)`
  // used to leave the suite green, because that spread sat past ORCH_BOUNDARY.
  // It is now inside buildResult, so the same mutation fails right here.
  //
  // The findings are stamped by the REAL applyJudgeVerdicts rather than
  // hand-written with `.nature`/`.disposition_rule` already set: the property at
  // risk is that findings genuinely carry those fields by the time they are
  // counted, and pre-stamping the fixture would assume away exactly that.
  {
    const findings = [mk("a.js#0", "high"), mk("a.js#1", "low"), mk("b.js#2", "medium")];
    applyJudgeVerdicts(
      findings,
      {
        verdicts: [
          { ref: "a.js#0", certainty: { level: "HIGH", confidence: 0.9 }, nature: "improvement", rationale: "x" },
          { ref: "a.js#1", certainty: { level: "LOW", confidence: 0.2 }, nature: "defect-in-new-code", rationale: "y" },
          { ref: "b.js#2", certainty: { level: "MEDIUM", confidence: 0.6 }, nature: "improvement", rationale: "z" },
        ],
      },
      false,
    );
    const r = buildResult({ rawFindings: findings });

    eq(
      r.summary.by_nature?.improvement,
      2,
      "buildResult: by_nature is counted from the findings, NOT an empty tally (#636 — PR #634 mutation 11)",
    );
    eq(
      r.summary.by_nature?.["defect-in-new-code"],
      1,
      "buildResult: by_nature counts a nature the deciding rule never names (#636)",
    );
    eq(
      r.summary.by_rule?.["R4-improvement"],
      2,
      "buildResult: by_rule is counted from the findings, NOT an empty tally (#636 — PR #634 mutation 11)",
    );
    eq(
      r.summary.by_rule?.["R2-low-certainty"],
      1,
      "buildResult: by_rule counts the rule that actually decided a finding (#636)",
    );
    // Teeth for the negative direction too: a suite that only checked "the keys
    // exist" would pass against the all-zero mutation.
    ok(
      Object.values(r.summary.by_nature).some((n) => n > 0),
      "buildResult: the by_nature distribution is non-zero for judged findings (#636)",
    );
    ok(
      Object.values(r.summary.by_rule).some((n) => n > 0),
      "buildResult: the by_rule distribution is non-zero for judged findings (#636)",
    );
    // Every known key still present at zero — the "never fired" vs "not
    // measured" distinction #613 exists to preserve.
    for (const k of NATURE_VALUES) {
      ok(
        Object.prototype.hasOwnProperty.call(r.summary.by_nature, k),
        `buildResult: by_nature pre-seeds the known nature "${k}" at zero (#613/#636)`,
      );
    }
    for (const k of DISPOSITION_RULES) {
      ok(
        Object.prototype.hasOwnProperty.call(r.summary.by_rule, k),
        `buildResult: by_rule pre-seeds the known rule "${k}" at zero (#613/#636)`,
      );
    }
  }

  // --- (1d) `clean` is COMPUTED, never passed through -----------------------
  //
  // Half the merge invariant. The three inputs are exercised one at a time, and
  // each alone must force false — an assertion that only tried all three
  // together would survive a mutation that dropped any single clause
  // (asymmetric-mutation trap).
  {
    eq(buildResult({}).clean, true, "buildResult: an empty, complete cycle is clean (#636)");
    eq(
      buildResult({ blocking: [mk("a.js#0", "high")] }).clean,
      false,
      "buildResult: a blocking finding alone forces clean false (#636)",
    );
    eq(
      buildResult({ unresolvedLen: 1 }).clean,
      false,
      "buildResult: an unresolved PR comment alone forces clean false (#636)",
    );
    eq(
      buildResult({ budgetExhausted: true }).clean,
      false,
      "buildResult: budget exhaustion alone forces clean false — clean is unforgeable by truncation (#270/#636)",
    );
    // A cycle with findings that ALL classify deferrable is still clean only if
    // it was complete: the exact combination #270 warns about.
    eq(
      buildResult({
        rawFindings: [mk("a.js#0", "low")],
        deferrable: [mk("a.js#0", "low")],
        budgetExhausted: true,
      }).clean,
      false,
      "buildResult: deferrable-only findings on a TRUNCATED cycle are not clean (#270/#636)",
    );
    eq(
      buildResult({
        rawFindings: [mk("a.js#0", "low")],
        deferrable: [mk("a.js#0", "low")],
      }).clean,
      true,
      "buildResult: deferrable-only findings on a COMPLETE cycle are clean (#636)",
    );
    // And `clean` cannot be handed in — a caller-supplied value must be ignored,
    // or the computation is decorative.
    eq(
      buildResult({ clean: true, budgetExhausted: true }).clean,
      false,
      "buildResult: a caller-supplied `clean` is ignored; the predicate decides (#636)",
    );
  }

  // --- (1e) The other two merge-invariant fields round-trip -----------------
  //
  // AC3 names these alongside `clean`.
  {
    const r = buildResult({
      budgetExhausted: true,
      dimensionsSkipped: ["security", "tests"],
      dimensionsRun: 3,
      noReviewSignal: true,
    });
    eq(r.budget_exhausted, true, "buildResult: budget_exhausted round-trips (#636)");
    eq(
      JSON.stringify(r.dimensions_skipped),
      JSON.stringify(["security", "tests"]),
      "buildResult: dimensions_skipped round-trips every name, not just the first (#636)",
    );
    eq(r.no_review_signal, true, "buildResult: no_review_signal round-trips (#636)");
    eq(r.token_report.dimensions_run, 3, "buildResult: dimensions_run round-trips into token_report (#636)");

    const d = buildResult({});
    eq(d.budget_exhausted, false, "buildResult: budget_exhausted defaults false, not undefined (#636)");
    eq(
      JSON.stringify(d.dimensions_skipped),
      "[]",
      "buildResult: dimensions_skipped defaults to an empty array (#636)",
    );
    eq(d.no_review_signal, false, "buildResult: no_review_signal defaults false, not undefined (#636)");
  }

  // --- (1f) by_disposition mirrors the partitioned buckets ------------------
  {
    const r = buildResult({
      rawFindings: [mk("a.js#0", "high"), mk("a.js#1", "low"), mk("b.js#2", "low")],
      blocking: [mk("a.js#0", "high")],
      deferrable: [mk("a.js#1", "low"), mk("b.js#2", "low")],
    });
    eq(r.summary.by_disposition.blocking, 1, "buildResult: by_disposition.blocking counts the bucket (#636)");
    eq(r.summary.by_disposition.deferrable, 2, "buildResult: by_disposition.deferrable counts the bucket (#636)");
    eq(r.blocking.length, 1, "buildResult: the blocking bucket is carried through (#636)");
    eq(r.deferrable.length, 2, "buildResult: the deferrable bucket is carried through (#636)");
  }

  // --- (1g) emptyResult still honours its contract after delegating ---------
  //
  // #636 rewrote emptyResult as a thin wrapper over buildResult. Its shape is
  // load-bearing on the manifest-failure path, so it is asserted directly rather
  // than assumed to follow from buildResult being correct.
  {
    const e = emptyResult({ budgetExhausted: false, dimensionsSkipped: [], dimensionsRun: 0, noReviewSignal: false });
    for (const k of TOP_LEVEL_KEYS) {
      ok(
        Object.prototype.hasOwnProperty.call(e, k),
        `emptyResult: still includes top-level key "${k}" after delegating to buildResult (#636)`,
      );
    }
    eq(e.summary.total_findings, 0, "emptyResult: reports zero findings (#636)");
    eq(JSON.stringify(e.blocking), "[]", "emptyResult: blocking is empty (#636)");
    eq(e.clean, true, "emptyResult: a complete empty cycle is clean (#636)");
    // Zeroed, NOT omitted — a measured zero-finding cycle must stay
    // distinguishable from one never measured (#553/#613).
    for (const k of NATURE_VALUES) {
      eq(e.summary.by_nature[k], 0, `emptyResult: by_nature["${k}"] is zeroed, not omitted (#613/#636)`);
    }
    for (const k of DISPOSITION_RULES) {
      eq(e.summary.by_rule[k], 0, `emptyResult: by_rule["${k}"] is zeroed, not omitted (#613/#636)`);
    }

    eq(
      emptyResult({ budgetExhausted: true, dimensionsSkipped: ["security"], dimensionsRun: 2, noReviewSignal: false }).clean,
      false,
      "emptyResult: a budget-truncated empty cycle is not clean (#270/#636)",
    );
    eq(
      emptyResult({ budgetExhausted: false, dimensionsSkipped: [], dimensionsRun: 0, noReviewSignal: true }).no_review_signal,
      true,
      "emptyResult: noReviewSignal reaches the result (#616/#636)",
    );

    // The two trailing params #636 added, which let the zero-findings call site
    // stop splicing fields onto the returned object past ORCH_BOUNDARY.
    const withComments = emptyResult({ budgetExhausted: false, dimensionsSkipped: [], dimensionsRun: 1, noReviewSignal: false, commentsAddressed: [{ id: "c1" }], unresolvedLen: 0 });
    eq(
      withComments.comments_addressed.length,
      1,
      "emptyResult: commentsAddressed is a parameter, not a post-hoc splice (#636)",
    );
    eq(
      emptyResult({ budgetExhausted: false, dimensionsSkipped: [], dimensionsRun: 1, noReviewSignal: false, commentsAddressed: [], unresolvedLen: 2 }).clean,
      false,
      "emptyResult: an unresolved comment count forces clean false through the same predicate (#636)",
    );
  }

  // --- (2) WIRING — the call sites, pinned against the raw source -----------
  //
  // Layer (1) proves buildResult is right; only this proves it is USED. Every
  // assertion above would keep passing if someone re-inlined the object literal
  // at the return, which is precisely the state #636 was filed about.
  //
  // Indentation-tolerant where the statement could legitimately be nested, per
  // workflow-authoring/SKILL.md — an absence check anchored at `^` inside a body
  // that is or becomes indented can never match, and stays green either way.
  {
    const orch = harnessSource(SHIP);

    ok(
      /^return buildResult\(\{/m.test(orch),
      "ship-issue: the terminal return is a column-0 `return buildResult({` — the ORCH_BOUNDARY residue is one call (#636)",
    );

    // Slice out JUST the terminal call's argument object before checking which
    // keys it passes. A whole-file `includes("  <key>,")` cannot do this job:
    // `emptyResult` delegates with the SAME keys at the SAME indentation, so the
    // file contains three `commentsAddressed,` lines and a check over `orch`
    // matches the wrapper's copy even when the terminal call has dropped its
    // own. Measured, not reasoned: with a whole-file check in place, deleting
    // `commentsAddressed,` from the terminal call left the suite green (review
    // cycle 1 found the missing key; the mutation then showed the obvious fix
    // did not bite either). The copy under test has to be the one addressed.
    const termStart = orch.search(/^return buildResult\(\{/m);
    const termEnd = orch.indexOf("})", termStart);
    ok(
      termStart >= 0 && termEnd > termStart,
      "ship-issue: the terminal buildResult call's argument object is delimited (#636)",
    );
    const termCall = orch.slice(termStart, termEnd);
    // NON-VACUITY, in the direction that can actually fail. The terminal call is
    // the LAST statement in the harness, so `emptyResult`'s delegation sits
    // ABOVE it: a slice that ran to end-of-file would still exclude the
    // wrapper, and a guard phrased as "the slice must not contain
    // emptyResult" is therefore vacuous — verified by mutating `termEnd` to
    // `orch.length`, which such a guard did not catch. What must be pinned is
    // that the slice STARTS at the terminal call (so it cannot drift upward to
    // cover the wrapper) and stays SMALL (so it cannot swallow the file).
    ok(
      termCall.startsWith("return buildResult({"),
      "ship-issue: the key-check slice starts AT the terminal call, so it cannot cover emptyResult's copy (#636)",
    );
    ok(
      termCall.length < 600 && !termCall.includes("function "),
      "ship-issue: the key-check slice is one call, not a widened window over the file (#636)",
    );
    // On `termEnd` specifically: mutating it to `orch.length` is a genuine
    // NO-OP here, not an untested path — the terminal call is the last
    // statement in the harness, so the widened slice gains exactly "})\n" (242
    // chars vs 245) and every key check above reads identical text. Measured
    // rather than assumed, and recorded so the next person to notice the
    // surviving mutation does not add an assertion that cannot fail. If a
    // future fragment is ever appended below 80-orchestration.js, this stops
    // being a no-op and the `length < 600` bound above is what catches it.

    // The fields the merge invariant reads are PASSED, not recomputed or
    // hardcoded at the call site. Named individually because a single
    // catch-all regex would pass while any one of them silently became a
    // literal.
    for (const key of [
      "rawFindings",
      "blocking",
      "deferrable",
      // `commentsAddressed` belongs here for the same reason as the rest, and
      // was missed in the first draft (review cycle 1). buildResult defaults it
      // to `[]`, so dropping this line from the terminal call does not throw —
      // every findings-present cycle would simply report `comments_addressed:
      // []` no matter what triage resolved. The sibling check in
      // 02-judge-disposition.mjs covers only the ZERO-findings emptyResult call,
      // so it could not see this one.
      "commentsAddressed",
      "budgetExhausted",
      "dimensionsSkipped",
      "noReviewSignal: allDimensionsFailed",
      "unresolvedLen: unresolvedComments.length",
      "dimensionsRun: dimensions.length",
    ]) {
      ok(
        termCall.includes(`  ${key},`),
        `ship-issue: the terminal buildResult call passes \`${key}\` (#636)`,
      );
    }

    // buildResult itself must stay ABOVE the boundary, or extractHelpers cannot
    // reach it and every assertion in layer (1) silently stops covering the
    // shipped code. Computed with the SAME regex the extractor uses (imported,
    // not retyped, so the two can never disagree), and reused below to scope the
    // absence checks.
    const boundary = orch.search(ORCH_BOUNDARY);
    const decl = orch.indexOf("function buildResult(");
    ok(decl >= 0, "ship-issue: buildResult is declared in the harness (#636)");
    ok(boundary > 0, "ship-issue: the harness has an orchestration boundary (#636)");
    ok(
      decl >= 0 && boundary >= 0 && decl < boundary,
      "ship-issue: buildResult is declared BEFORE ORCH_BOUNDARY, so extractHelpers can reach it (#636)",
    );

    // The inlined derivations are GONE FROM THE ORCHESTRATION BODY. Scoped to
    // the region past the boundary, not the whole file: every one of these
    // expressions still exists — that is the point of the change, they moved
    // INTO buildResult — so a whole-file absence check would fail against the
    // correct fix, and "relax it until green" would have deleted the assertion's
    // teeth. What must be absent is specifically an UNREACHABLE copy.
    const body = orch.slice(boundary);
    ok(
      !/^[ \t]*const bySeverity = \{/m.test(body),
      "ship-issue: the by_severity tally no longer runs past ORCH_BOUNDARY (#636)",
    );
    ok(
      !/^[ \t]*\.\.\.summarizeJudgeObservations\(/m.test(body),
      "ship-issue: the #613 distributions are no longer spread past ORCH_BOUNDARY (#636 — PR #634 mutation 11)",
    );
    ok(
      !/^[ \t]*r\.clean = computeClean\(/m.test(body),
      "ship-issue: `clean` is no longer spliced onto the empty result past ORCH_BOUNDARY (#636)",
    );
    // The scoping above is only meaningful if the slice is non-vacuous and
    // really excludes the prefix. Pin both directions, or a boundary that
    // drifted to end-of-file would make all three checks pass trivially.
    ok(
      body.includes("return buildResult({") && !body.includes("function buildResult("),
      "ship-issue: the past-boundary slice holds the call site but not the declaration (scoping is real) (#636)",
    );
    ok(
      /const bySeverity = \{/.test(orch.slice(0, boundary)),
      "ship-issue: the by_severity tally DOES exist before the boundary — it moved, it was not deleted (#636)",
    );
  }
}
