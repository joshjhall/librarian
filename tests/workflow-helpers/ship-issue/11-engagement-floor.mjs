// ship-issue area — the engagement floor (issue #1111)
//
// A review dimension that RETURNS `findings: []` having read nothing used to be
// counted clean: 54 of 250 measured reviewer runs were a lone StructuredOutput
// call of ~53 output tokens. This area pins the floor at the three places it
// lives:
//
//   (1) BEHAVIOUR of `classifyEngagement` — the truth table, including the
//       operator's correction to the plan: a diff-only answer is unengaged ONLY
//       for a dimension whose job requires reading code. `scope-drift` compares
//       the diff against the issue, so a diff-only scope-drift result is
//       ENGAGED; classifying it otherwise would retry it every cycle and block
//       convergence forever.
//   (2) BEHAVIOUR of the result constructor — a stub empty-submit dimension fed
//       through buildResult/emptyResult must not read clean (AC5), and the
//       unengaged list must force the partial flag even if a call site forgets
//       to (the derivation lives inside buildResult, past nothing).
//   (3) WIRING past ORCH_BOUNDARY — the null-preserving `.then`, the opus
//       re-dispatch, and both returns passing the new fields, pinned against the
//       raw source because no extracted helper can reach them.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export function run() {
  const { classifyEngagement, CODE_READING_DIMENSIONS, FINDINGS_SCHEMA, buildResult, emptyResult } = extractHelpers(
    SHIP,
    ["classifyEngagement", "CODE_READING_DIMENSIONS", "FINDINGS_SCHEMA", "buildResult", "emptyResult"],
    { cycle: 1, phase: "pre-pr", files: ["a.js"] },
  );

  const finding = { file: "a.js", line_start: 1, category: "security", severity: "high" };
  const diffOnly = [{ target: "a.js", how: "diff-only" }];
  const read = [{ target: "a.js", how: "read" }];

  // --- (1) classifyEngagement truth table -----------------------------------
  {
    eq(classifyEngagement("security", null), "failed", "engagement: a null result is 'failed', kept on the #846 partial path");
    // THE issue's signature: StructuredOutput({findings: []}) and nothing else.
    eq(
      classifyEngagement("security", { findings: [], checked: [] }),
      "unengaged",
      "engagement: empty findings + empty checked is unengaged (#1111 AC1)",
    );
    // Empty-checked is unengaged for EVERY dimension, not only code readers —
    // an answer naming nothing it examined has no evidence of any kind.
    eq(
      classifyEngagement("scope-drift", { findings: [], checked: [] }),
      "unengaged",
      "engagement: empty checked is unengaged even for a diff-only dimension",
    );
    // A model whose output omits `checked` entirely is the same as empty.
    eq(
      classifyEngagement("correctness", { findings: [] }),
      "unengaged",
      "engagement: an absent checked field reads as empty, never as engaged",
    );
    eq(classifyEngagement("security", { findings: [finding], checked: [] }), "engaged", "engagement: any finding is engagement");
    eq(classifyEngagement("security", { findings: [], checked: read }), "engaged", "engagement: a read file with no findings is engaged");
    for (const dim of ["security", "correctness", "tests"]) {
      eq(
        classifyEngagement(dim, { findings: [], checked: diffOnly }),
        "unengaged",
        `engagement: a diff-only answer from code-reading dimension "${dim}" is unengaged`,
      );
    }
    // The operator's correction: these dimensions are LEGITIMATELY diff-only.
    eq(
      classifyEngagement("scope-drift", { findings: [], checked: [{ target: "issue ACs vs diff", how: "diff-only" }] }),
      "engaged",
      "engagement: a diff-only scope-drift result is ENGAGED — it compares the diff to the issue (operator note on #1111)",
    );
    eq(
      classifyEngagement("decomposition", { findings: [], checked: diffOnly }),
      "engaged",
      "engagement: a diff-only decomposition result is engaged — it judges the pre-scan's numbers",
    );
    // One real read among diff-only entries is engagement for a code reader.
    eq(
      classifyEngagement("security", { findings: [], checked: [...diffOnly, ...read] }),
      "engaged",
      "engagement: a mixed checked list with one real read is engaged",
    );
    // The list itself — pinned so a later edit adding scope-drift here (which
    // would reopen the never-converges failure) is a visible test change.
    eq(
      [...CODE_READING_DIMENSIONS].sort().join(","),
      "correctness,security,tests",
      "engagement: CODE_READING_DIMENSIONS is exactly security/correctness/tests",
    );
  }

  // --- AC3: the schema requires the evidence field --------------------------
  {
    ok(FINDINGS_SCHEMA.required.includes("checked"), "schema: FINDINGS_SCHEMA requires `checked` (#1111 AC3)");
    ok(FINDINGS_SCHEMA.required.includes("findings"), "schema: FINDINGS_SCHEMA still requires `findings`");
    eq(
      [...FINDINGS_SCHEMA.properties.checked.items.properties.how.enum].sort().join(","),
      "diff-only,grep,ran,read",
      "schema: `checked[].how` is the closed enum the classifier keys off",
    );
  }

  // --- (2) AC5: a stub empty-submit dimension is not counted clean -----------
  {
    // Feed the stub through the classifier and then the constructor, the way
    // the orchestration body does: unengaged -> unengagedDimensions +
    // dimensionsSkipped.
    const stub = { findings: [], checked: [] };
    const verdict = classifyEngagement("security", stub);
    const unengaged = verdict === "unengaged" ? ["security"] : [];
    const r = emptyResult({
      budgetExhausted: false,
      dimensionsSkipped: [...unengaged],
      unengagedDimensions: unengaged,
      dimensionsRun: 5,
      noReviewSignal: false,
    });
    eq(r.clean, false, "AC5: a stub empty-submit security dimension does not produce clean:true (#1111)");
    eq(r.budget_exhausted, true, "AC5: the unengaged cycle is partial");
    ok(r.dimensions_skipped.includes("security"), "AC5: the unengaged dimension is listed in dimensions_skipped");
    ok(r.unengaged_dimensions.includes("security"), "AC5: ...and in unengaged_dimensions, which says why");
    // Charged, not uncharged: a dimension that disengages every cycle must
    // dead-end at the cap, not loop forever as a no-signal cycle.
    eq(r.no_review_signal, false, "AC5: unengaged is NOT no_review_signal (it is charged against the cap)");

    // buildResult DERIVES the partial flag from the list, so a call site that
    // passes the list but forgets budgetExhausted still cannot report clean.
    const forgot = buildResult({ unengagedDimensions: ["tests"], budgetExhausted: false });
    eq(forgot.clean, false, "buildResult: a non-empty unengaged list forces clean:false on its own");
    eq(forgot.budget_exhausted, true, "buildResult: ...by forcing budget_exhausted");

    // The negative direction: an engaged empty cycle stays clean, so the floor
    // does not make every zero-finding cycle unterminable.
    const engaged = emptyResult({ budgetExhausted: false, dimensionsSkipped: [], unengagedDimensions: [], dimensionsRun: 5 });
    eq(engaged.clean, true, "buildResult: an engaged zero-finding cycle is still clean");
    eq(JSON.stringify(engaged.unengaged_dimensions), "[]", "buildResult: unengaged_dimensions is always present, [] when none");
    eq(JSON.stringify(engaged.dimension_engagement), "{}", "buildResult: dimension_engagement is always present");

    const eng = { security: { engagement: "engaged", checked: 2, retried: true, requires_code_reading: true } };
    eq(
      emptyResult({ dimensionEngagement: eng }).dimension_engagement.security.retried,
      true,
      "emptyResult: dimension_engagement is passed through (AC4, in-sandbox half)",
    );
  }

  // --- (3) WIRING past ORCH_BOUNDARY ----------------------------------------
  {
    const orch = harnessSource(SHIP);
    // The #846 mechanism: `(r && r.findings) || []` turned a dead dimension into
    // a non-null empty result that the partial-cycle guard never saw.
    ok(
      !orch.includes("findings: (r && r.findings) || []"),
      "wiring: a null dimension result is no longer wrapped into a non-null empty one (#846 mechanism)",
    );
    const keepNull = orch.match(/\.then\(\(r\) => \(r \? \{ dim: entry\.dim\.name, findings: r\.findings \|\| \[\], checked: r\.checked \|\| \[\] \} : null\)\)/g) || [];
    eq(keepNull.length, 2, "wiring: both the first dispatch and the opus retry preserve null and carry `checked`");

    const retryStart = orch.indexOf("const retried = await parallel(");
    ok(retryStart >= 0, "wiring: unengaged dimensions are re-dispatched under parallel()");
    const retryBlock = orch.slice(retryStart, retryStart + 1200);
    ok(retryBlock.includes("model: 'opus'"), "wiring: the re-dispatch runs on opus (#1111 proposal 3)");

    const mainIdx = orch.indexOf("const rawFindings = []\nreviewResults.forEach((res, i) => {");
    ok(mainIdx >= 0, "wiring: the main results loop is locatable");
    const mainLoop = orch.slice(mainIdx, mainIdx + 2000);
    ok(
      mainLoop.includes("unengagedDimensions.push(name)") && mainLoop.includes("dimensionsSkipped.push(name)"),
      "wiring: an unengaged dimension lands in both unengagedDimensions and dimensionsSkipped",
    );

    // Both returns must pass the new fields — buildResult defaults them to
    // empty, so a dropped key would not throw, it would just silently report
    // every cycle as engaged.
    const termStart = orch.search(/^return buildResult\(\{/m);
    const termCall = orch.slice(termStart, orch.indexOf("})", termStart));
    const emptyStart = orch.indexOf("  return emptyResult({\n    budgetExhausted,");
    const emptyCall = orch.slice(emptyStart, orch.indexOf("})", emptyStart));
    ok(emptyStart >= 0, "wiring: the zero-findings emptyResult call is locatable");
    for (const key of ["unengagedDimensions,", "dimensionEngagement,"]) {
      ok(termCall.includes(key), `wiring: the terminal buildResult call passes ${key.slice(0, -1)}`);
      ok(emptyCall.includes(key), `wiring: the zero-findings emptyResult call passes ${key.slice(0, -1)}`);
    }
  }
}
