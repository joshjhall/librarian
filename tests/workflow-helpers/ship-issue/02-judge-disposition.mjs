// ship-issue area — judge verdict application and disposition calibration (#712).
//
// Split out of tests/workflow-helpers/ship-issue.mjs (see 01-pure-helpers.mjs for
// why). Content moved VERBATIM; only indentation and import depth changed.
//
// Covers: applyJudgeVerdicts's four branches (#491), the dispositionOf calibration
// gate (#580), nature retention (#613), tallyBy / summarizeJudgeObservations, and
// the emptyResult / computeClean / sameCommentId result-shape predicates.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
  const {
    refOf,
    emptyResult,
    computeAllDimensionsFailed,
    computeClean,
    sameCommentId,
    JUDGE_SCHEMA,
    applyJudgeVerdicts,
    dispositionOf,
    tallyBy,
    summarizeJudgeObservations,
    NATURE_VALUES,
    DISPOSITION_RULES,
  } = extractHelpers(
    SHIP,
    [
      "refOf",
      "emptyResult",
      "computeAllDimensionsFailed",
      "computeClean",
      "sameCommentId",
      "JUDGE_SCHEMA",
      "applyJudgeVerdicts",
      "dispositionOf",
      "tallyBy",
      "summarizeJudgeObservations",
      "NATURE_VALUES",
      "DISPOSITION_RULES",
    ],
    { cycle: 2, phase: "pr-cycle", files: ["x.js"] },
  );

  // applyJudgeVerdicts (#491): the merged Judge stage's apply/fallback + partition,
  // extracted (like computeClean) so the single-pass invariant is testable against
  // a FIXTURE finding set — issue #491 AC #4 ("Blocking/deferrable classification
  // equivalent on a fixture finding set"). Covers the three behavioral branches the
  // old two-stage rescore→classify flow spread across two agents.
  const mkFinding = (ref, level = "LOW", conf = 0.4) => ({
    ref,
    certainty: { level, confidence: conf, support: 1, method: "producer" },
    severity: "high",
  });

  // (a) Success: certainty AND nature come from the SAME verdict (keyed by ref),
  // the disposition is computed by dispositionOf from the RE-SCORED certainty,
  // and the findings partition accordingly.
  {
    const findings = [mkFinding("a#0"), mkFinding("b#1"), mkFinding("c#2")];
    const judged = {
      verdicts: [
        { ref: "a#0", certainty: { level: "HIGH", confidence: 0.9 }, nature: "defect-in-new-code", rationale: "x" },
        { ref: "b#1", certainty: { level: "LOW", confidence: 0.2 }, nature: "defect-in-new-code", rationale: "y" },
        { ref: "c#2", certainty: { level: "MEDIUM", confidence: 0.6 }, nature: "incomplete-work", rationale: "z" },
      ],
    };
    const res = applyJudgeVerdicts(findings, judged, false);
    eq(res.blocking.length, 2, "applyJudgeVerdicts: two blocking-computing verdicts partition to blocking");
    eq(res.deferrable.length, 1, "applyJudgeVerdicts: one deferrable-computing verdict partitions to deferrable");
    eq(res.budgetExhausted, false, "applyJudgeVerdicts: a complete judge does not force budgetExhausted");
    // The re-scored certainty was applied in place from the matching verdict.
    eq(findings[0].certainty.level, "HIGH", "applyJudgeVerdicts: certainty level re-scored from the same verdict");
    eq(findings[0].certainty.confidence, 0.9, "applyJudgeVerdicts: certainty confidence re-scored from the same verdict");
    // The blocking set is the computed one (not merely the first entries).
    ok(
      res.blocking.some((f) => f.ref === "a#0") && res.blocking.some((f) => f.ref === "c#2"),
      "applyJudgeVerdicts: blocking set is exactly the refs whose verdict computes blocking",
    );
    ok(res.deferrable[0]?.ref === "b#1", "applyJudgeVerdicts: LOW-certainty verdict lands in deferrable");
    // The deciding rule is stamped so a surfaced finding can say WHY it blocks.
    eq(
      res.deferrable[0]?.disposition_rule,
      "R2-low-certainty",
      "applyJudgeVerdicts: stamps the deciding rule onto the finding (#580)",
    );

    // The policy reads the RE-SCORED certainty, not the producer's. This is the
    // ordering guarantee inside applyJudgeVerdicts (certainty is written before
    // dispositionOf is called) and it is load-bearing: a producer-LOW finding
    // the judge raises to MEDIUM must block. Reversing those two statements
    // would silently defer every finding the judge upgraded.
    const upgraded = [mkFinding("up#0", "LOW", 0.3)];
    const upRes = applyJudgeVerdicts(upgraded, {
      verdicts: [
        { ref: "up#0", certainty: { level: "MEDIUM", confidence: 0.6 }, nature: "defect-in-new-code", rationale: "r" },
      ],
    }, false);
    eq(
      upRes.blocking.length,
      1,
      "applyJudgeVerdicts: policy reads the judge's re-scored certainty, not the producer's (#580)",
    );
  }

  // (b) Null judge (budget-skipped / threw): certainty is left untouched, the
  // cycle is forced partial (budgetExhausted=true), and every finding defaults to
  // DEFERRABLE (filed, never dropped) — the "clean unforgeable by truncation"
  // invariant (#270).
  {
    const findings = [mkFinding("a#0", "MEDIUM", 0.5), mkFinding("b#1")];
    const res = applyJudgeVerdicts(findings, null, false);
    eq(res.budgetExhausted, true, "applyJudgeVerdicts: null judge forces budgetExhausted true");
    eq(res.blocking.length, 0, "applyJudgeVerdicts: null judge blocks nothing");
    eq(res.deferrable.length, 2, "applyJudgeVerdicts: null-judge findings all default to deferrable");
    eq(findings[0].certainty.level, "MEDIUM", "applyJudgeVerdicts: null judge leaves producer certainty untouched");
  }

  // (c) A finding whose ref the judge OMITTED defaults per budgetExhausted:
  // blocking when the budget was NOT exhausted (surfaced, never silently ignored),
  // deferrable when it was (filed).
  {
    const findings = [mkFinding("seen#0"), mkFinding("missing#1")];
    const judged = {
      verdicts: [
        { ref: "seen#0", certainty: { level: "LOW", confidence: 0.3 }, nature: "defect-in-new-code", rationale: "x" },
      ],
    };
    const notExhausted = applyJudgeVerdicts(
      [mkFinding("seen#0"), mkFinding("missing#1")],
      judged,
      false,
    );
    ok(
      notExhausted.blocking.some((f) => f.ref === "missing#1"),
      "applyJudgeVerdicts: an unmatched ref defaults to blocking when budget not exhausted",
    );
    const exhausted = applyJudgeVerdicts(findings, judged, true);
    ok(
      exhausted.deferrable.some((f) => f.ref === "missing#1"),
      "applyJudgeVerdicts: an unmatched ref defaults to deferrable when budget exhausted",
    );
  }

  // (d) The judge's `nature` is RETAINED on the finding (#613).
  //
  // Why this matters enough to pin. `nature` is the axis the whole disposition
  // policy turns on, and before #613 it was read by `dispositionOf` and then
  // dropped — so a systematic miscall (an `improvement` label on what is really
  // a `defect-in-new-code`) was uncountable after the fact, which is the same
  // invisibility #580 was filed to end. `disposition_rule` cannot stand in for
  // it: only R4/R5/R6 name a nature, while R2 and R8 — the two highest-volume
  // rules — do not.
  {
    const findings = [
      mkFinding("keep#0", "HIGH", 0.9),
      mkFinding("keep#1", "LOW", 0.2),
      mkFinding("gone#2", "HIGH", 0.9),
    ];
    const judged = {
      verdicts: [
        { ref: "keep#0", certainty: { level: "HIGH", confidence: 0.9 }, nature: "improvement", rationale: "x" },
        { ref: "keep#1", certainty: { level: "LOW", confidence: 0.2 }, nature: "defect-in-new-code", rationale: "y" },
      ],
    };
    applyJudgeVerdicts(findings, judged, false);

    // Stamped verbatim — NOT re-derived from the deciding rule. `keep#0` is the
    // case that separates the two: it is decided by R4, which does name a
    // nature, so it alone would pass either way.
    eq(findings[0]?.nature, "improvement", "applyJudgeVerdicts: stamps the judge's nature onto the finding (#613)");

    // The load-bearing one. `keep#1` is decided by R2-low-certainty, which
    // short-circuits ABOVE every nature rule — so its nature is unrecoverable
    // from `disposition_rule` and can only be present if it was genuinely
    // retained. Asserting only the R4 case above would be tautological.
    eq(
      findings[1]?.nature,
      "defect-in-new-code",
      "applyJudgeVerdicts: retains nature even when the deciding rule (R2) does not name one (#613)",
    );
    eq(findings[1]?.disposition_rule, "R2-low-certainty", "applyJudgeVerdicts: …and that rule is indeed R2");

    // nature and certainty come from the SAME verdict — the existing
    // same-verdict guarantee, now extended to the third field keyed by ref.
    eq(findings[0]?.certainty?.level, "HIGH", "applyJudgeVerdicts: nature and certainty come from the same verdict");

    // A finding the judge omitted gets NO nature — it must not inherit a
    // neighbour's. This is the `nature` analogue of the ref-collision bug the
    // refOf comment documents, and it is what keeps the tally from inventing
    // an observation the judge never made.
    eq(findings[2]?.nature, undefined, "applyJudgeVerdicts: an unmatched ref is left without a nature (#613)");
  }

  // (e) tallyBy: the per-cycle distribution counters behind the #613 measures.
  {
    // The four nature values and eight rule names must stay in lockstep with
    // the policy — a tally keyed off a drifted list under-counts silently.
    eq(
      JSON.stringify(NATURE_VALUES),
      JSON.stringify([
        "defect-in-new-code",
        "defect-in-preexisting-code",
        "incomplete-work",
        "improvement",
      ]),
      "NATURE_VALUES: exactly the four judge observations (#613)",
    );
    eq(
      JSON.stringify(DISPOSITION_RULES),
      JSON.stringify([
        "R1-critical",
        "R2-low-certainty",
        "R3-security-high",
        "R4-improvement",
        "R5-preexisting",
        "R6-incomplete",
        "R7-large-effort",
        "R8-defect-in-new-code",
      ]),
      "DISPOSITION_RULES: exactly the eight rules dispositionOf can return (#613)",
    );
    // JUDGE_SCHEMA's enum is the SAME list — the desync this constant exists
    // to prevent, asserted rather than assumed.
    eq(
      JSON.stringify(JUDGE_SCHEMA?.properties?.verdicts?.items?.properties?.nature?.enum),
      JSON.stringify(NATURE_VALUES),
      "JUDGE_SCHEMA: nature enum is NATURE_VALUES, so schema and tally cannot drift (#613)",
    );

    const counts = tallyBy(
      ["improvement", "improvement", "defect-in-new-code"],
      NATURE_VALUES,
    );
    eq(counts["improvement"], 2, "tallyBy: counts repeated values");
    eq(counts["defect-in-new-code"], 1, "tallyBy: counts a single value");
    // Present-and-zero, not absent. A rule that never fires in production is
    // itself the signal (#613 — dead or mis-ordered), so "0" and "missing"
    // must not be the same observation.
    eq(counts["incomplete-work"], 0, "tallyBy: an unseen key is present at zero, not absent (#613)");
    ok(
      Object.prototype.hasOwnProperty.call(counts, "defect-in-preexisting-code"),
      "tallyBy: every known key is pre-seeded even at zero (#613)",
    );
    // Undefined is skipped, not bucketed — a finding the judge omitted must
    // not invent an observation.
    const withGaps = tallyBy([undefined, "improvement", null], NATURE_VALUES);
    eq(withGaps["improvement"], 1, "tallyBy: skips undefined/null rather than counting them");
    eq(
      Object.values(withGaps).reduce((a, b) => a + b, 0),
      1,
      "tallyBy: gaps contribute nothing to the total (#613)",
    );
    // An unknown value is counted under its own key, never dropped — so a
    // future fifth nature degrades to "missing its zero row", not "invisible".
    const unknown = tallyBy(["surprise"], NATURE_VALUES);
    eq(unknown["surprise"], 1, "tallyBy: an unknown value is counted, not silently dropped (#613)");

    // `nature` is LLM-supplied, so a prototype-adjacent value must count like
    // any other string. On a plain `{}` the inherited `__proto__` setter
    // ignores a numeric assignment and the value is SILENTLY SWALLOWED — no
    // own key, no count, no error — which is precisely the "never dropped"
    // property above, failing on the one input most likely to be adversarial.
    // A null-prototype accumulator has no such setter. (Review cycle 1.)
    const proto = tallyBy(["__proto__", "__proto__", "constructor"], NATURE_VALUES);
    eq(proto["__proto__"], 2, "tallyBy: a __proto__ value is counted, not swallowed by the setter (#613)");
    eq(proto["constructor"], 1, "tallyBy: a constructor value is counted as an ordinary key (#613)");
    // And the real prototype is untouched — the accumulator inherits nothing.
    eq(Object.getPrototypeOf(proto), null, "tallyBy: accumulator has a null prototype (#613)");
    eq(({}).__proto__, Object.prototype, "tallyBy: Object.prototype is not polluted (#613)");
  }

  // (e2) summarizeJudgeObservations: the two distributions, composed.
  //
  // Extracted from the return object so this composition is testable at all —
  // that `rawFindings` genuinely carry `.nature` / `.disposition_rule` by the
  // time they are counted is the part that can silently regress, and it was
  // previously only reachable by running the whole harness. (Review cycle 1.)
  //
  // KNOWN GAP, stated rather than implied: the single `...summarize…(rawFindings)`
  // spread in the harness's return object sits past ORCH_BOUNDARY, so
  // extractHelpers cannot reach it and no assertion here covers it. Replacing
  // that call with `tallyBy([], …)` still passes this suite. What the extraction
  // buys is that the LOGIC is now pinned; the one-line wiring is verified by the
  // live harness run instead (a cycle whose summary reports non-zero counts).
  {
    // Compose the two units the way the harness does: judge verdicts in,
    // distributions out — so a break in the wiring between them is caught.
    const findings = [
      mkFinding("s#0", "HIGH", 0.9),
      mkFinding("s#1", "LOW", 0.2),
      mkFinding("s#2", "MEDIUM", 0.6),
    ];
    applyJudgeVerdicts(
      findings,
      {
        verdicts: [
          { ref: "s#0", certainty: { level: "HIGH", confidence: 0.9 }, nature: "improvement", rationale: "a" },
          { ref: "s#1", certainty: { level: "LOW", confidence: 0.2 }, nature: "defect-in-new-code", rationale: "b" },
          { ref: "s#2", certainty: { level: "MEDIUM", confidence: 0.6 }, nature: "improvement", rationale: "c" },
        ],
      },
      false,
    );
    const s = summarizeJudgeObservations(findings);
    eq(s?.by_nature?.["improvement"], 2, "summarizeJudgeObservations: counts nature off the stamped findings (#613)");
    eq(
      s?.by_nature?.["defect-in-new-code"],
      1,
      "summarizeJudgeObservations: counts a nature the deciding rule never names (#613)",
    );
    eq(s?.by_nature?.["incomplete-work"], 0, "summarizeJudgeObservations: unseen nature present at zero (#613)");
    eq(s?.by_rule?.["R2-low-certainty"], 1, "summarizeJudgeObservations: counts the deciding rule (#613)");
    eq(s?.by_rule?.["R4-improvement"], 2, "summarizeJudgeObservations: counts repeated rules (#613)");
    eq(s?.by_rule?.["R8-defect-in-new-code"], 0, "summarizeJudgeObservations: unfired rule present at zero (#613)");

    // A finding the judge skipped contributes to NEITHER distribution, so the
    // counts never exceed what the judge actually observed — and the gap from
    // total_findings stays readable as "not every finding was characterized".
    const withGap = [mkFinding("g#0", "HIGH", 0.9), mkFinding("g#1", "HIGH", 0.9)];
    applyJudgeVerdicts(
      withGap,
      {
        verdicts: [
          { ref: "g#0", certainty: { level: "HIGH", confidence: 0.9 }, nature: "improvement", rationale: "a" },
        ],
      },
      false,
    );
    const gapped = summarizeJudgeObservations(withGap);
    eq(
      Object.values(gapped?.by_nature || {}).reduce((a, b) => a + b, 0),
      1,
      "summarizeJudgeObservations: an unjudged finding contributes to no bucket (#613)",
    );
  }

  // (f) emptyResult carries both distributions, zeroed — a zero-finding cycle
  // is a real row in the tally, and omitting the keys would make it read as
  // "not measured" (the same reasoning that puts token_report on this path).
  {
    const r = emptyResult(false, undefined, []);
    eq(r.summary?.by_nature?.["defect-in-new-code"], 0, "emptyResult: by_nature present and zeroed (#613)");
    eq(r.summary?.by_rule?.["R8-defect-in-new-code"], 0, "emptyResult: by_rule present and zeroed (#613)");
    eq(
      Object.keys(r.summary?.by_nature || {}).length,
      4,
      "emptyResult: by_nature carries all four nature keys (#613)",
    );
    eq(
      Object.keys(r.summary?.by_rule || {}).length,
      8,
      "emptyResult: by_rule carries all eight rule keys (#613)",
    );
  }

  // --- dispositionOf: the #580 calibration gate ---------------------------
  //
  // Why this block exists. The policy it guards shipped UNSATISFIABLE and no
  // test noticed for 26 review cycles: BLOCKING required
  // `severity ∈ {critical, high}` while DEFERRABLE fired on
  // `severity ∈ {medium, low}` OR `certainty == LOW`, and producers emit
  // medium/low almost exclusively — so the medium band was swallowed whole and
  // `blocking` fired once in 67 findings. `clean` is computed from
  // `blocking == []`, so the merge gate was unguarded the entire time.
  //
  // The gate is designed to FAIL against that old predicate. The specific trap
  // it avoids: asserting merely "some input produces blocking" would ALSO pass
  // the old policy, via its critical/high row — a textbook tautology (the
  // fixture both arms the gate and satisfies it). So the load-bearing
  // assertions below pin the cells at the severity producers ACTUALLY emit.
  {
    const SEVERITIES = ["critical", "high", "medium", "low"];
    const LEVELS = ["HIGH", "MEDIUM", "LOW"];
    const EFFORTS = ["trivial", "small", "medium", "large"];
    // Read from the harness's own exported constants rather than re-listing
    // them here (review cycle 4). These were hand-maintained duplicates, which
    // is the exact desync NATURE_VALUES / DISPOSITION_RULES exist to prevent:
    // add a ninth rule, update the exports, miss this copy, and the totality +
    // reachability grid below would keep passing over a stale rule set while
    // the tally already counted the new key. Referencing the source removes the
    // drift rather than asserting it away — there is no second list left to
    // fall out of step. The literal shape of both lists is pinned separately in
    // block (e), so this is not a self-referential "grid agrees with itself".
    const NATURES = NATURE_VALUES;
    const RULES = DISPOSITION_RULES;
    // A finding at the shape the review harness actually produces. Defaults sit
    // at the observed producer distribution (medium severity, MEDIUM certainty,
    // small effort) so every case below states only what it varies.
    const f = (o = {}) => ({
      severity: "medium",
      category: "correctness",
      effort: "small",
      certainty: { level: "MEDIUM", confidence: 0.6, support: 1, method: "producer" },
      ...o,
    });
    const disp = (o, nature = "defect-in-new-code") => dispositionOf(f(o), nature)?.disposition;
    const rule = (o, nature = "defect-in-new-code") => dispositionOf(f(o), nature)?.rule;

    // (1) SATISFIABILITY at the observed producer distribution. THE assertion
    // that fails the old policy: severity medium + MEDIUM certainty + a real
    // defect in code this PR wrote. Every one of the six defects the batch
    // deferred looked exactly like this. Under the old predicate this cell was
    // deferrable (medium severity hit the DEFERRABLE `OR`); it must block now.
    eq(
      disp({}),
      "blocking",
      "dispositionOf: severity=medium + MEDIUM certainty + defect-in-new-code BLOCKS — the cell the old policy could not reach (#580)",
    );
    eq(
      disp({ severity: "low" }),
      "blocking",
      "dispositionOf: even severity=low blocks for a confirmed new-code defect — severity is not the axis (#580)",
    );
    // Severity is DEMOTED, not merely reweighted: for a new-code defect at
    // non-LOW certainty the disposition is invariant across all four
    // severities. A regression that re-promoted severity to the primary axis
    // fails here even if it kept the medium cell blocking.
    ok(
      SEVERITIES.every((severity) => disp({ severity }) === "blocking"),
      "dispositionOf: a MEDIUM-certainty new-code defect blocks at EVERY severity (severity is demoted, #580)",
    );

    // (2) The six defects the #567 batch deferred while returning `blocking: []`,
    // at their recorded severity/certainty. Each is a real confirmed defect in
    // code its own PR had just written — the regression corpus for this issue.
    //
    // Honest scope: these six share a code path (none is LOW certainty, so all
    // fall past R2 to R8) and therefore pass or fail together — they are one
    // assertion's worth of coverage, not six. They are kept as named fixtures
    // because the corpus is the evidence FOR the policy: if a future change
    // defers any of them again, the failure names the exact historical defect
    // it would have re-admitted, which a bare "medium/MEDIUM blocks" assertion
    // does not. Coverage comes from (1), (3) and (4); this block is the record.
    const MISSED = [
      ["#533", "MEDIUM", 0.6, "absent-matcher swallowed a tmux permission-denied error"],
      ["#542", "MEDIUM", 0.6, "dispatch tests were textual only — swapped arm bodies still passed"],
      ["#544", "HIGH", 0.87, "bounded-probe test never exercised the bound"],
      ["#549", "HIGH", 0.92, "IFS=: -> bare read re-opened the parity class the PR was closing"],
      ["#568", "HIGH", 0.85, ".mjs/.cjs routed for missing-test-file but not debug-statement"],
      ["#568", "HIGH", 0.88, "parity gate asserted over a fixture list with no file of the changed extension"],
    ];
    for (const [issue, level, confidence, what] of MISSED) {
      eq(
        disp({ certainty: { level, confidence, support: 1, method: "producer" } }),
        "blocking",
        `dispositionOf: ${issue} (${level}/${confidence}) blocks — ${what} (#580 regression corpus)`,
      );
    }

    // (3) Deferral still works. The fix must not be "block everything" — a
    // policy that blocks unconditionally would pass (1) and (2) while making
    // every cycle dead-end at the review cap.
    eq(
      disp({ certainty: { level: "LOW", confidence: 0.3, support: 1, method: "producer" } }),
      "deferrable",
      "dispositionOf: LOW certainty defers — a speculative defect never blocks",
    );
    eq(disp({}, "improvement"), "deferrable", "dispositionOf: an improvement defers");
    eq(
      disp({}, "defect-in-preexisting-code"),
      "deferrable",
      "dispositionOf: a defect in code this PR did not touch defers (fixing it is scope creep)",
    );
    eq(
      disp({ effort: "large" }),
      "deferrable",
      "dispositionOf: a large fix is its own issue even when the defect is real and in new code",
    );

    // (4) Rule ORDER is the semantics. Each case below inverts if the two rules
    // it straddles are swapped, so a reordering cannot pass silently.
    eq(
      rule({ severity: "critical", certainty: { level: "LOW", confidence: 0.2, support: 1, method: "producer" } }),
      "R2-low-certainty",
      "dispositionOf: R1 does not fire at LOW certainty — an unconfident critical still defers",
    );
    eq(
      rule({ severity: "critical", effort: "large" }),
      "R1-critical",
      "dispositionOf: R1 outranks R7 — a critical defect is not deferred for being large",
    );
    eq(
      rule({ category: "security", certainty: { level: "HIGH", confidence: 0.9, support: 1, method: "producer" } }, "improvement"),
      "R3-security-high",
      "dispositionOf: R3 outranks R4 — a confirmed security finding blocks even when characterized as an improvement",
    );
    eq(
      rule({ effort: "large" }, "incomplete-work"),
      "R6-incomplete",
      "dispositionOf: R6 outranks R7 — incomplete work is not shippable regardless of remaining effort",
    );
    eq(
      rule({ certainty: { level: "LOW", confidence: 0.2, support: 1, method: "producer" } }, "incomplete-work"),
      "R2-low-certainty",
      "dispositionOf: R2 outranks R6 — an unconfident incompleteness claim defers",
    );

    // (5) TOTALITY. Every cell of the grid decides, and no rule is dead code.
    // The old policy's failure mode was a band that neither branch claimed
    // cleanly; this asserts the replacement cannot have one.
    const seenRules = new Set();
    let undecided = 0;
    let badRule = 0;
    for (const severity of SEVERITIES) {
      for (const level of LEVELS) {
        for (const effort of EFFORTS) {
          for (const nature of NATURES) {
            for (const category of ["correctness", "security", "tests", "scope-drift"]) {
              const out = dispositionOf(
                f({ severity, effort, category, certainty: { level, confidence: 0.5, support: 1, method: "producer" } }),
                nature,
              );
              if (out?.disposition !== "blocking" && out?.disposition !== "deferrable") undecided++;
              if (!RULES.includes(out?.rule)) badRule++;
              else seenRules.add(out.rule);
            }
          }
        }
      }
    }
    eq(undecided, 0, "dispositionOf: every grid cell yields a valid disposition (the policy is TOTAL, #580)");
    eq(badRule, 0, "dispositionOf: every grid cell names a known rule");
    const unreached = RULES.filter((r) => !seenRules.has(r));
    eq(
      unreached.join(",") || "(none)",
      "(none)",
      "dispositionOf: every rule is reachable from some grid cell — no dead rule (#580)",
    );
    // Both dispositions occur across the grid. Guards the two degenerate
    // directions: a policy that blocks everything (which would pass (1) and (2)
    // while dead-ending every cycle at the review cap), and one that — like its
    // predecessor — effectively blocks nothing.
    let gridBlocking = 0;
    let gridDeferrable = 0;
    for (const nature of NATURES) {
      for (const level of LEVELS) {
        const d = dispositionOf(
          f({ certainty: { level, confidence: 0.5, support: 1, method: "producer" } }),
          nature,
        )?.disposition;
        if (d === "blocking") gridBlocking++;
        if (d === "deferrable") gridDeferrable++;
      }
    }
    ok(gridBlocking > 0, "dispositionOf: the grid produces blocking findings — not block-nothing (#580)");
    ok(gridDeferrable > 0, "dispositionOf: the grid still produces deferrable findings — not block-everything");
  }

  const r = emptyResult(false);
  eq(r.cycle, 2, "emptyResult: cycle reflects args");
  eq(r.phase, "pr-cycle", "emptyResult: phase reflects args");
  eq(r.clean, true, "emptyResult: clean defaults true for the complete empty case");
  eq(r.blocking.length, 0, "emptyResult: no blocking findings");
  eq(r.summary.files_scanned, 1, "emptyResult: files_scanned from scopeFiles");
  ok(
    Array.isArray(r.dimensions_skipped) && r.dimensions_skipped.length === 0,
    "emptyResult: dimensions_skipped is an empty array on the complete path",
  );
  // #270: a budget-truncated cycle is PARTIAL — never clean, even with no
  // findings — and it names the dimensions that never ran. This is the
  // merge-invariant guard: `clean` must be unforgeable by truncation.
  const truncated = emptyResult(true, undefined, ["tests", "conventions"]);
  eq(truncated.clean, false, "emptyResult: budget-truncated empty cycle is NOT clean");
  eq(truncated.budget_exhausted, true, "emptyResult: budget_exhausted reflects the arg");
  eq(
    JSON.stringify(truncated.dimensions_skipped),
    JSON.stringify(["tests", "conventions"]),
    "emptyResult: dimensions_skipped names the dimensions that did not run",
  );
  // #616: `no_review_signal` distinguishes a cycle that CRASHED before any
  // dimension ran from one that reviewed and found nothing. The convergence
  // helper reads it to decline charging the cycle against REVIEW_MAX_CYCLES,
  // so a false positive here would silently stop the cycle cap from binding.
  eq(r.no_review_signal, false, "emptyResult: no_review_signal defaults false for a complete cycle");
  eq(
    truncated.no_review_signal,
    false,
    "emptyResult: a budget-truncated cycle DID review — partial, not no-signal (#616)",
  );
  const crashed = emptyResult(false, undefined, [], 0, true);
  eq(crashed.no_review_signal, true, "emptyResult: no_review_signal set on the crash path (#616)");
  // A fan-out-wide wipeout is as void of review signal as a dead manifest, and
  // must be flagged the same way — otherwise #616 is only half fixed: the
  // crash point moves one phase later and the cycle charges the cap again.
  const wipeout = emptyResult(true, undefined, ["security", "correctness"], 2, true);
  eq(wipeout.no_review_signal, true, "emptyResult: an all-dimensions-failed cycle is no-signal (#616)");
  eq(wipeout.clean, false, "emptyResult: a wipeout is still not clean (it is also partial)");
  // The field is always present, never conditionally omitted: the helper's
  // default for an absent field is `false`, so omitting it on one path and
  // emitting it on another would make the two indistinguishable downstream.
  ok(
    Object.prototype.hasOwnProperty.call(r, "no_review_signal"),
    "emptyResult: no_review_signal is always present, not conditionally omitted",
  );
  // The wipeout detection itself lives in the ORCHESTRATION body (past
  // ORCH_BOUNDARY), so no extracted helper can reach it — assert structurally
  // that the flag is both computed and threaded, like the sibling checks below.
  // Without this, `emptyResult` could accept the 5th arg correctly while the
  // zero-findings call site never passes it, and the behavioral test above
  // would still pass.
  {
    const orch = harnessSource(SHIP);
    // Derived from the DISPATCHED results, never from a
    // `dimensionsSkipped.length === dimensions.length` count comparison —
    // those two lengths mix disjoint populations (a build-time skip names a
    // dimension never added to `dimensions`; a mid-barrier null names one that
    // was), so they can coincide while every dispatched dimension succeeded.
    // Pin both the right shape and the absence of the wrong one.
    ok(
      /const allDimensionsFailed\s*=\s*computeAllDimensionsFailed\(reviewResults, dimensionsSkipped\)/.test(orch),
      "ship-issue: the orchestration body calls the extracted predicate, not an inline copy (#616)",
    );
    // The field must be present on BOTH return paths, not just emptyResult's.
    // The reader defaults an absent key to false, so an omission on the
    // findings-bearing path is indistinguishable from an explicit false — and
    // the behavioral assertions above, which only exercise emptyResult, cannot
    // see that path at all. Count the sites: one in emptyResult, one in the
    // non-empty-findings return object.
    eq(
      (orch.match(/^\s*no_review_signal:/gm) || []).length,
      2,
      "ship-issue: no_review_signal is emitted on BOTH return paths, never omitted on one (#616)",
    );
    // ...and the findings-bearing path must emit the COMPUTED flag, not a
    // literal. Counting emission sites cannot see the value, which is how a
    // hardcoded `false` survived cycle 6: having findings does NOT imply a
    // dimension reported, because `rawFindings` also collects comment-triage
    // findings, and triage is gated on TAIL_FLOOR (8k) while the fan-out is
    // gated on BUDGET_FLOOR (40k) — so a starved fan-out plus a surviving
    // comment finding is reachable in normal operation.
    ok(
      /^\s*no_review_signal: allDimensionsFailed,/m.test(orch),
      "ship-issue: the findings-bearing return emits the computed flag, not a hardcoded false (#616)",
    );
    ok(
      !/^\s*no_review_signal: false,/m.test(orch),
      "ship-issue: no return path hardcodes no_review_signal false",
    );
    // The two floors are what make that state reachable; if they were ever
    // equalized the hazard would vanish, and this comment would be stale
    // rather than wrong. Pin the ordering the reasoning depends on.
    {
      const floor = Number((orch.match(/const BUDGET_FLOOR = ([\d_]+)/) || [])[1]?.replace(/_/g, ""));
      const tail = Number((orch.match(/const TAIL_FLOOR = ([\d_]+)/) || [])[1]?.replace(/_/g, ""));
      ok(
        Number.isFinite(floor) && Number.isFinite(tail) && tail < floor,
        "ship-issue: TAIL_FLOOR < BUDGET_FLOOR — comment triage outlives the fan-out (#616 hazard)",
      );
    }
    ok(
      !/allDimensionsFailed\s*=\s*[^\n]*dimensionsSkipped\.length === dimensions\.length/.test(orch),
      "ship-issue: the wipeout case is NOT a skipped-vs-selected count comparison (false no-signal)",
    );

    // The predicate's own truth table, run against the REAL extracted
    // function — not a copy of it. The regexes above pin the SHAPE; this pins
    // the BEHAVIOR. The two rows that matter produce an identical empty
    // `reviewResults` and are distinguishable only by whether a review was
    // owed: a `reviewResults.length > 0` guard passes rows 1, 2 and 4 and
    // fails only row 3, which is exactly the bug cycle 5 found.
    //
    // Calling the real function is the point (cycle 8). A local
    // reimplementation would keep passing while the harness's own copy drifted
    // — and this predicate has drifted five times, so a test that cannot see
    // the production code is the wrong test for it.
    const wipeoutOf = computeAllDimensionsFailed;
    eq(wipeoutOf([{ dim: "security" }, null], []), false, "wipeout: a dimension that reported is review signal");
    eq(wipeoutOf([null, null], ["security", "tests"]), true, "wipeout: every dispatched dimension failed");
    eq(wipeoutOf([], ["scope-drift"]), true, "wipeout: budget skipped every candidate BEFORE dispatch (#616)");
    eq(wipeoutOf([], []), false, "wipeout: narrowing legitimately selected nothing — complete, not no-signal");
    const zeroCall = orch.slice(orch.indexOf("if (rawFindings.length === 0) {"));
    ok(
      zeroCall.slice(0, 400).includes("allDimensionsFailed"),
      "ship-issue: the zero-findings emptyResult call threads allDimensionsFailed (#616)",
    );
  }
  // A no-signal cycle is still not clean by virtue of the flag alone — the
  // manifest-failure call site sets `clean = false` explicitly. Pin that the
  // flag does not accidentally imply cleanliness in either direction.
  eq(crashed.clean, true, "emptyResult: no_review_signal alone does not force clean false (caller does)");

  // #270: computeClean is the shared predicate behind BOTH return paths,
  // including the non-empty-findings path that sits past the ORCH_BOUNDARY and
  // so is otherwise untestable. The merge-invariant guarantee — a truncated
  // cycle is never clean even when nothing blocks — is asserted here directly.
  eq(computeClean(0, 0, false), true, "computeClean: complete + no blockers + no open comments is clean");
  eq(computeClean(1, 0, false), false, "computeClean: any blocking finding is not clean");
  eq(computeClean(0, 1, false), false, "computeClean: any unresolved comment is not clean");
  eq(
    computeClean(0, 0, true),
    false,
    "computeClean: budget-truncated cycle is NOT clean even with zero blockers (merge invariant, #270)",
  );
  // #261: PR comment ids arrive numeric from `gh pr view` but COMMENTS_SCHEMA
  // coerces triaged ids to strings. A strict `===` never matched, so every
  // comment read as unresolved forever (clean unreachable). sameCommentId
  // normalizes both sides — the numeric-vs-string path is the core regression.
  eq(sameCommentId(123, "123"), true, "sameCommentId: numeric gh id matches its string schema id (#261)");
  eq(sameCommentId("123", 123), true, "sameCommentId: order-independent numeric/string match");
  eq(sameCommentId(123, 123), true, "sameCommentId: two numeric ids match");
  eq(sameCommentId("abc", "abc"), true, "sameCommentId: two string ids match");
  eq(sameCommentId(123, 456), false, "sameCommentId: distinct numeric ids do not match");
  eq(sameCommentId("abc", "def"), false, "sameCommentId: distinct string ids do not match");
}
