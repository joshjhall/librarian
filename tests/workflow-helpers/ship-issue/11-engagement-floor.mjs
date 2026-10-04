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
//   (2) BEHAVIOUR end to end (AC5, #1129) — the REAL harness body is driven
//       with stubbed engine globals, and a stub empty-submit dimension must come
//       back in the returned cycle JSON as not-clean, in both skip lists. AC5
//       once rebuilt the classify-then-push glue by hand, so deleting either
//       real push left it green. Plus the result constructor's own rule: the
//       unengaged list forces the partial flag even if a call site forgets to.
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

// Run the WHOLE ship-issue harness — pure prefix AND orchestration body — with
// stubbed engine globals, and return the cycle JSON it produces. extractHelpers
// cannot reach past ORCH_BOUNDARY (its `new Function` body may not contain a
// top-level `await`); an AsyncFunction body may, and the harness's top-level
// `return` is then the function's return. `agentStub(prompt, opts)` answers each
// dispatch; `parallel` nulls a thrown thunk, as the engine does. Single-use, so
// it stays in this area rather than in tests/lib (CLAUDE.md).
const AsyncFunction = (async () => {}).constructor;
async function runHarness(agentStub, args) {
  const src = harnessSource(SHIP).replace(/^export\s+const\s+meta/m, "const meta");
  const calls = [];
  const logs = [];
  const agent = async (prompt, opts) => {
    calls.push(opts);
    return agentStub(prompt, opts);
  };
  const parallel = (thunks) =>
    Promise.all(
      thunks.map(async (t) => {
        try {
          return await t();
        } catch {
          return null;
        }
      }),
    );
  const budget = { total: null, spent: () => 0, remaining: () => Infinity };
  const body = new AsyncFunction("args", "budget", "log", "phase", "agent", "parallel", "pipeline", src);
  const result = await body(args, budget, (m) => logs.push(m), () => {}, agent, parallel, async () => []);
  return { result, calls, logs };
}

export async function run() {
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
    // Driven through the REAL orchestration body (#1129): classification, the
    // opus retry, stampEngagement, and the `dimensionsSkipped.push` that lives
    // past ORCH_BOUNDARY all run as shipped. Deleting either push fails here.
    const harnessArgs = { cycle: 1, phase: "pre-pr", files: ["a.js"], diff: "diff --git a/a.js b/a.js\n+x" };
    const manifest = { files: ["a.js"], classifications: [{ file: "a.js", types: ["code"] }], needs: { database: false, devops: false } };
    const stubFor = (emptyDim) => (_prompt, opts) => {
      if (opts.label === "manifest") return manifest;
      // `checked` OMITTED, not empty: the dispatch `.then` must default it, so
      // this is also the end-to-end checked-absent case.
      if (opts.label === `review:${emptyDim}`) return { findings: [] };
      return { findings: [], checked: read };
    };

    let driven = null;
    try {
      driven = await runHarness(stubFor("security"), harnessArgs);
    } catch (err) {
      ok(false, `AC5: the driven harness ran to completion — threw ${err?.message || err}`);
    }
    const r = driven?.result || {};
    const calls = driven?.calls || [];
    // Non-vacuity: the stubs were actually consulted, and the floor's retry fired.
    ok(calls.some((c) => c.label === "manifest"), "AC5: the driven run dispatched the manifest agent");
    const secCalls = calls.filter((c) => c.label === "review:security");
    eq(secCalls.length, 2, "AC5: the empty-submit dimension was dispatched, then re-dispatched once");
    eq(secCalls[1]?.model, "opus", "AC5: ...the re-dispatch on opus");

    eq(r.clean, false, "AC5: a stub empty-submit security dimension does not produce clean:true (#1111)");
    eq(r.budget_exhausted, true, "AC5: the unengaged cycle is partial");
    ok((r.dimensions_skipped || []).includes("security"), "AC5: the unengaged dimension is listed in dimensions_skipped");
    ok((r.unengaged_dimensions || []).includes("security"), "AC5: ...and in unengaged_dimensions, which says why");
    eq(r.dimension_engagement?.security?.engagement, "unengaged", "AC5: dimension_engagement reports it unengaged");
    eq(r.dimension_engagement?.security?.checked, 0, "AC5: an omitted checked field is counted as zero, not thrown on");
    // Only the empty dimension is listed — a harness that lists every dimension
    // would satisfy the includes() checks above.
    eq(JSON.stringify(r.unengaged_dimensions), '["security"]', "AC5: no engaged dimension is reported unengaged");
    eq(JSON.stringify(r.dimensions_skipped), '["security"]', "AC5: no engaged dimension is reported skipped");
    // Charged, not uncharged: a dimension that disengages every cycle must
    // dead-end at the cap, not loop forever as a no-signal cycle.
    eq(r.no_review_signal, false, "AC5: unengaged is NOT no_review_signal (it is charged against the cap)");

    // Control: the same drive with every dimension engaged IS clean, so AC5's
    // not-clean verdict is caused by the empty dimension, not by the harness
    // reporting every stubbed cycle partial.
    let control = null;
    try {
      control = (await runHarness(stubFor("none"), harnessArgs)).result;
    } catch (err) {
      ok(false, `AC5 control: the driven harness ran to completion — threw ${err?.message || err}`);
    }
    eq(control?.clean, true, "AC5 control: an all-engaged driven cycle is clean");
    eq(JSON.stringify(control?.dimensions_skipped), "[]", "AC5 control: ...and skips nothing");

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
    eq(
      JSON.stringify(emptyResult({ dimensionEngagement: null }).dimension_engagement),
      "{}",
      "emptyResult: a null dimension_engagement becomes {}, never null",
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

    // A result with `checked` (and `findings`) ABSENT — the dispatch `.then`
    // always sets both today, but nothing else guarantees it (#1129).
    let bare = null;
    try {
      bare = stampEngagement([{ dim: { name: "tests" } }], [{ dim: "tests" }], [], []);
    } catch (err) {
      ok(false, `stamp: a result missing checked/findings is not thrown on — threw ${err?.message || err}`);
    }
    eq(bare?.dimensionEngagement.tests.checked, 0, "stamp: an absent checked field counts as 0");
    eq(bare?.dimensionEngagement.tests.findings, 0, "stamp: an absent findings field counts as 0");
    eq(bare?.dimensionEngagement.tests.engagement, "unengaged", "stamp: ...and the result is unengaged");
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
    // Whitespace-tolerant: a reformat of the destructuring must not fail the pin.
    eq(
      (orch.match(/\{\s*results:\s*reviewResults,\s*retrySucceeded\s*\}\s*=\s*mergeRetried\(reviewResults,\s*retryIdx,\s*retried\)/g) || []).length,
      1,
      "wiring: the retries are folded back by mergeRetried, into reviewResults, once",
    );
    eq(
      count("const stamped = stampEngagement(dimensions, reviewResults, retryIdx, retrySucceeded)"),
      1,
      "wiring: the results are stamped by stampEngagement, once",
    );
    ok(orch.includes("if (stamped.partial) budgetExhausted = true"), "wiring: stampEngagement's partial flag sets budgetExhausted");
    ok(orch.includes("dimensionsSkipped.push(...stamped.skippedAdds)"), "wiring: stampEngagement's skip list feeds dimensionsSkipped");
    // The per-dimension log keys its message off unengagedDimensions: swapping
    // the arms would report an unengaged dimension as failed in the run log.
    ok(
      /log\(\s*unengagedDimensions\.includes\(name\)\s*\?\s*`dimension "\$\{name\}" returned without reviewing \(unengaged\)/.test(orch),
      "wiring: an unengaged dimension is logged as unengaged, not as failed",
    );
    ok(
      /returned without reviewing \(unengaged\) — cycle now partial`\s*:\s*`dimension "\$\{name\}" did not complete \(failed or budget-skipped\)/.test(orch),
      "wiring: a failed or budget-skipped dimension takes the ternary's other arm",
    );

    // The opus re-dispatch: matched on the agent() options object itself, so a
    // `model: 'opus'` in a nearby comment cannot satisfy it.
    const retryThunk = orch.match(
      /const retried = await parallel\(\s*retryIdx\.map\(\(i\) => \(\) => \{([\s\S]*?)\n\s*\}\)\s*\)\n/,
    );
    ok(retryThunk, "wiring: unengaged dimensions are re-dispatched under parallel()");
    const thunk = retryThunk ? retryThunk[1] : "";
    ok(
      /return agent\(prompt, \{(?:\s*\w+: [^\n]+,)*?\s*model: 'opus',/.test(thunk),
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
