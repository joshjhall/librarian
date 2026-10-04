// ship-issue area — the engagement floor (issue #1111)
//
// A review dimension that RETURNS `findings: []` having read nothing used to be
// counted clean: 54 of 250 measured reviewer runs were a lone StructuredOutput
// call of ~53 output tokens. This area pins the floor at the four places it
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
//   (3) BEHAVIOUR of the retry path (#1128) — `selectRetries`, `mergeRetried`,
//       and `stampEngagement`: an engaged retry replaces, a null or
//       budget-skipped retry keeps the unengaged original, and `retry_*` and the
//       partial flag are stamped from what actually happened.
//   (4) WIRING past ORCH_BOUNDARY — the null-preserving `.then`, the opus
//       re-dispatch, one call to each helper, and both returns passing the new
//       fields, pinned against the raw source as call-site checks.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export function run() {
  const {
    classifyEngagement,
    CODE_READING_DIMENSIONS,
    FINDINGS_SCHEMA,
    buildResult,
    emptyResult,
    selectRetries,
    mergeRetried,
    stampEngagement,
  } = extractHelpers(
    SHIP,
    [
      "classifyEngagement",
      "CODE_READING_DIMENSIONS",
      "FINDINGS_SCHEMA",
      "buildResult",
      "emptyResult",
      "selectRetries",
      "mergeRetried",
      "stampEngagement",
    ],
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

    const eng = { security: { engagement: "engaged", checked: 2, retry_attempted: true, retry_succeeded: false, requires_code_reading: true } };
    eq(
      emptyResult({ dimensionEngagement: eng }).dimension_engagement.security.retry_attempted,
      true,
      "emptyResult: dimension_engagement is passed through (AC4, in-sandbox half)",
    );
  }

  // --- (3) BEHAVIOUR of the retry path (#1128) --------------------------------
  //
  // The selection, merge, and stamping used to be inline past ORCH_BOUNDARY,
  // pinned only by source greps that kept passing with the replace line deleted
  // or inverted. They are pure helpers now, so each outcome is exercised here.
  {
    const dims = ["security", "tests", "scope-drift"].map((name) => ({ dim: { name } }));
    const unengaged = (dim) => ({ dim, findings: [], checked: [] });
    const engagedRetry = { dim: "security", findings: [finding], checked: read };
    // security: unengaged; tests: unengaged; scope-drift: engaged with a real read.
    const first = [unengaged("security"), unengaged("tests"), { dim: "scope-drift", findings: [], checked: read }];

    eq(JSON.stringify(selectRetries(dims, first)), "[0,1]", "retry: only the unengaged dimensions are selected");
    eq(
      JSON.stringify(selectRetries(dims, [null, first[1], first[2]])),
      "[1]",
      "retry: a null (failed) result is never a retry candidate — the #846 path owns it",
    );

    // security's retry engages; tests' retry returns null (agent null, or the
    // thunk declined to spend below BUDGET_FLOOR — both arrive as null).
    const retryIdx = selectRetries(dims, first);
    const snapshot = JSON.stringify(first);
    const { results, retrySucceeded } = mergeRetried(first, retryIdx, [engagedRetry, null]);
    eq(JSON.stringify(first), snapshot, "retry: mergeRetried does not mutate the first-pass results");
    ok(results[0] === engagedRetry, "retry: an engaged retry REPLACES the original result");
    ok(results[1] === first[1], "retry: a null retry KEEPS the original unengaged result");
    ok(results[2] === first[2], "retry: a dimension that was not retried is untouched");
    eq(JSON.stringify(retrySucceeded), "[0]", "retry: retrySucceeded names only the retry that returned a result");

    const st = stampEngagement(dims, results, retryIdx, retrySucceeded);
    eq(st.dimensionEngagement.security.engagement, "engaged", "stamp: the engaged retry is no longer reported unengaged");
    ok(!st.unengagedDimensions.includes("security"), "stamp: ...and is absent from unengagedDimensions");
    eq(st.rawFindings.length, 1, "stamp: the engaged retry's finding reaches rawFindings");
    eq(st.rawFindings[0].dimension, "security", "stamp: the raw finding is tagged with its dimension");
    // The kept original must stay UNENGAGED, not fall to 'failed': that would
    // lose the reason the dimension was missed.
    eq(st.dimensionEngagement.tests.engagement, "unengaged", "stamp: a null retry leaves the dimension unengaged, not failed");
    eq(JSON.stringify(st.unengagedDimensions), '["tests"]', "stamp: the still-unengaged dimension is listed in unengagedDimensions");
    eq(JSON.stringify(st.skippedAdds), '["tests"]', "stamp: ...and in skippedAdds, which feeds dimensionsSkipped");
    eq(st.partial, true, "stamp: an unengaged dimension makes the cycle partial (judge defaults to deferrable)");

    // retry_attempted vs retry_succeeded across the three cases.
    const e = st.dimensionEngagement;
    eq([e.security.retry_attempted, e.security.retry_succeeded].join(), "true,true", "stamp: selected + succeeded");
    eq([e.tests.retry_attempted, e.tests.retry_succeeded].join(), "true,false", "stamp: selected + null retry is attempted, not succeeded");
    eq([e["scope-drift"].retry_attempted, e["scope-drift"].retry_succeeded].join(), "false,false", "stamp: not selected");
    eq(e.security.findings, 1, "stamp: dimension_engagement records the raw per-dimension finding count");
    eq(e.tests.requires_code_reading, true, "stamp: requires_code_reading is stamped from CODE_READING_DIMENSIONS");
    eq(e["scope-drift"].requires_code_reading, false, "stamp: ...and false for a diff-only dimension");

    // The skip list keeps iteration order across unengaged and failed entries.
    const mixed = stampEngagement(dims, [null, first[1], first[2]], [1], []);
    eq(JSON.stringify(mixed.skippedAdds), '["security","tests"]', "stamp: skippedAdds keeps iteration order across failed and unengaged");
    eq(mixed.dimensionEngagement.security.engagement, "failed", "stamp: a null first-pass result stays 'failed'");
    ok(!mixed.unengagedDimensions.includes("security"), "stamp: a failed dimension is not reported unengaged");

    // The negative direction: an all-engaged cycle is not partial.
    const clean = stampEngagement(dims, [engagedRetry, first[2], first[2]], [], []);
    eq(clean.partial, false, "stamp: an all-engaged cycle is not partial");
    eq(clean.skippedAdds.length, 0, "stamp: ...and skips nothing");
  }

  // --- (4) WIRING past ORCH_BOUNDARY ----------------------------------------
  //
  // Only the dispatch and the call sites remain in the orchestration body; the
  // behavior above is what the helpers do, and these pins prove the body calls them.
  {
    const orch = harnessSource(SHIP);
    const count = (s) => orch.split(s).length - 1;
    // The #846 mechanism: `(r && r.findings) || []` turned a dead dimension into
    // a non-null empty result that the partial-cycle guard never saw.
    ok(
      !orch.includes("findings: (r && r.findings) || []"),
      "wiring: a null dimension result is no longer wrapped into a non-null empty one (#846 mechanism)",
    );
    const keepNull = orch.match(/\.then\(\(r\) => \(r \? \{ dim: entry\.dim\.name, findings: r\.findings \|\| \[\], checked: r\.checked \|\| \[\] \} : null\)\)/g) || [];
    eq(keepNull.length, 2, "wiring: both the first dispatch and the opus retry preserve null and carry `checked`");

    eq(count("const retryIdx = selectRetries(dimensions, reviewResults)"), 1, "wiring: retries are selected by selectRetries, once");
    eq(
      count(";({ results: reviewResults, retrySucceeded } = mergeRetried(reviewResults, retryIdx, retried))"),
      1,
      "wiring: the retries are folded back by mergeRetried, once",
    );
    eq(
      count("const stamped = stampEngagement(dimensions, reviewResults, retryIdx, retrySucceeded)"),
      1,
      "wiring: the results are stamped by stampEngagement, once",
    );
    ok(orch.includes("if (stamped.partial) budgetExhausted = true"), "wiring: stampEngagement's partial flag sets budgetExhausted");
    ok(orch.includes("dimensionsSkipped.push(...stamped.skippedAdds)"), "wiring: stampEngagement's skip list feeds dimensionsSkipped");

    // The opus re-dispatch: matched on the agent() options object itself, so a
    // `model: 'opus'` in a nearby comment cannot satisfy it.
    const retryThunk = orch.match(
      /const retried = await parallel\(\n {4}retryIdx\.map\(\(i\) => \(\) => \{\n([\s\S]*?)\n {4}\}\)\n {2}\)/,
    );
    ok(retryThunk, "wiring: unengaged dimensions are re-dispatched under parallel()");
    const thunk = retryThunk ? retryThunk[1] : "";
    ok(
      /return agent\(prompt, \{\n(?: {8}\w+: [^\n]+,\n)*? {8}model: 'opus',\n/.test(thunk),
      "wiring: the re-dispatch's agent() options run on opus (#1111 proposal 3)",
    );
    ok(
      thunk.includes("if (reviewBudget.total && reviewBudget.remaining() < BUDGET_FLOOR) return null"),
      "wiring: the retry thunk declines to spend below BUDGET_FLOOR (yielding the null mergeRetried keeps)",
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
