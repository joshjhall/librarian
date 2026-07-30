// ci-fixer — workflow.js pure-helper tests (issue #564 split).
//
// Pure-helper coverage for the ci-fixer workflow.js harness.
//
// Covers defaultVerdict.
//
// Extracted verbatim from tests/validate-workflow-helpers.mjs. Assertions are
// collect-all (they record, never throw), so a failure here does not mask any
// sibling area — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../lib/mjs-assert.mjs";
import { extractHelpers, CIFIX } from "../lib/extract-helpers.mjs";

export function run() {
  // =============================================================================
  // ci-fixer — defaultVerdict
  // =============================================================================
  {
    const { defaultVerdict, transientVerdict, applyResult, wrapVerify, parsePrompt, needsClassify } =
      extractHelpers(CIFIX, [
        "defaultVerdict",
        "transientVerdict",
        "applyResult",
        "wrapVerify",
        "parsePrompt",
        "needsClassify",
      ]);

    // #493 — classify is memoized OUT of the per-iteration path: it reads only the
    // static `check.logs`, so parsePrompt is iteration-independent. Guard the
    // contract at the arity + prompt-text level (the orchestration loop itself is
    // not unit-testable — two-runtime engine).
    eq(parsePrompt.length, 1, "parsePrompt: takes only `check` (no iteration arg) after the #493 hoist");
    const pp = parsePrompt({ name: "lint", pr: 7, logs: "eslint: 3 errors in a.js" });
    ok(
      !/attempt/i.test(pp),
      "parsePrompt: no per-attempt framing — classification runs once, not once per iteration",
    );
    ok(pp.includes("eslint: 3 errors in a.js"), "parsePrompt: embeds the failure logs");
    ok(pp.includes("Check name: lint"), "parsePrompt: interpolates check.name");
    ok(pp.includes("PR: #7"), "parsePrompt: interpolates check.pr");

    // #493 — needsClassify is the memoization decision: classify fires only when
    // `cls` is not already a truthy memoized result. A successful classify is
    // reused (skips re-classify); a null/undefined is left uncached so it retries
    // next iteration — the pre-existing transient semantics, unchanged.
    eq(needsClassify(null), true, "needsClassify: a null cls (first iter / retried null) → classify");
    eq(needsClassify(undefined), true, "needsClassify: an undefined cls → classify");
    eq(
      needsClassify({ failure_type: "lint", files: ["a.js"], summary: "3 errors" }),
      false,
      "needsClassify: a memoized classify result → skip re-classify (the #493 win)",
    );
    const v = defaultVerdict({ name: "lint" });
    eq(v.fixed, false, "defaultVerdict: fixed is false until proven otherwise");
    eq(
      JSON.stringify(v.remainingFailures),
      JSON.stringify(["lint"]),
      "defaultVerdict: remainingFailures seeds the check name",
    );
    eq(v.failure_type, "other", "defaultVerdict: failure_type defaults to 'other'");

    // #259 — transientVerdict: a stage failed transiently, but an applied fix
    // must still surface its files_changed (the "silent working-tree mutation"
    // bug) and the classify failure_type must carry through.
    const check = { name: "lint" };
    const tvApplied = transientVerdict(
      check,
      { failure_type: "lint" },
      { applied: true, files_changed: ["a.js"], summary: "ran eslint --fix" },
    );
    eq(tvApplied.agentVerdict, false, "transientVerdict: marked as not an agent verdict");
    eq(tvApplied.fixed, false, "transientVerdict: never reports fixed");
    eq(tvApplied.failure_type, "lint", "transientVerdict: failure_type comes from classify");
    eq(
      JSON.stringify(tvApplied.remainingFailures),
      JSON.stringify(["lint"]),
      "transientVerdict: remainingFailures seeds the check name",
    );
    eq(
      JSON.stringify(tvApplied.files_changed),
      JSON.stringify(["a.js"]),
      "transientVerdict: an applied fix surfaces its files_changed",
    );
    const tvNoFix = transientVerdict(check, null, null);
    eq(tvNoFix.failure_type, "other", "transientVerdict: no classify → failure_type 'other'");
    eq(
      JSON.stringify(tvNoFix.files_changed),
      JSON.stringify([]),
      "transientVerdict: no applied fix → empty files_changed",
    );
    const tvNotApplied = transientVerdict(
      check,
      { failure_type: "type" },
      { applied: false, files_changed: ["b.ts"], summary: "no edit" },
    );
    eq(
      JSON.stringify(tvNotApplied.files_changed),
      JSON.stringify([]),
      "transientVerdict: a fix that did not apply reports no files_changed",
    );

    // #259 — applyResult: the loop-control fold. Null → retry (never break out on
    // the seeded default); an agent-returned 'other'+!fixed → stop; any other
    // agent verdict or synthesized transient → keep going.
    const prev = defaultVerdict(check);
    const rNull = applyResult(prev, null);
    eq(rNull.stop, false, "applyResult: null result never stops the loop");
    eq(rNull.verdict, prev, "applyResult: null result keeps the prior verdict untouched");

    const rOther = applyResult(prev, {
      agentVerdict: true,
      fixed: false,
      failure_type: "other",
      summary: "infra timeout",
      files_changed: [],
      remainingFailures: ["lint"],
    });
    eq(rOther.stop, true, "applyResult: an agent-returned 'other'+!fixed stops the loop");
    eq(
      "agentVerdict" in rOther.verdict,
      false,
      "applyResult: the internal agentVerdict marker is stripped from the adopted verdict",
    );

    const rLint = applyResult(prev, {
      agentVerdict: true,
      fixed: false,
      failure_type: "lint",
      summary: "still failing",
      files_changed: ["a.js"],
      remainingFailures: ["lint"],
    });
    eq(rLint.stop, false, "applyResult: an agent 'lint'+!fixed retries (not unfixable)");

    const rFixed = applyResult(prev, {
      agentVerdict: true,
      fixed: true,
      failure_type: "other",
      summary: "passes now",
      files_changed: ["a.js"],
      remainingFailures: [],
    });
    eq(rFixed.stop, false, "applyResult: a fixed 'other' verdict adopts without stopping");
    eq(rFixed.verdict.fixed, true, "applyResult: adopts the agent's fixed=true");

    const rTransient = applyResult(prev, tvApplied);
    eq(rTransient.stop, false, "applyResult: a synthesized transient verdict retries");
    eq(
      JSON.stringify(rTransient.verdict.files_changed),
      JSON.stringify(["a.js"]),
      "applyResult: a transient result carries its applied files_changed onto the verdict",
    );
    eq(
      rTransient.verdict.failure_type,
      "lint",
      "applyResult: a transient result carries its failure_type onto the verdict",
    );
    const rTransientEmpty = applyResult(
      { ...prev, files_changed: ["kept.js"] },
      transientVerdict(check, { failure_type: "type" }, null),
    );
    eq(
      JSON.stringify(rTransientEmpty.verdict.files_changed),
      JSON.stringify(["kept.js"]),
      "applyResult: an empty transient files_changed preserves the prior verdict's edits",
    );

    // #259 — a transient result must NOT downgrade a prior REAL classification.
    // prev is the adoption of an agent 'lint' verdict; a later generic transient
    // (from a null classify) must keep prev's failure_type/summary intact.
    const realPrev = applyResult(defaultVerdict(check), {
      agentVerdict: true,
      fixed: false,
      failure_type: "lint",
      summary: "still 3 lint errors in foo.js",
      files_changed: ["foo.js"],
      remainingFailures: ["lint"],
    }).verdict;
    const rLateTransient = applyResult(realPrev, transientVerdict(check, null, null));
    eq(
      rLateTransient.verdict.failure_type,
      "lint",
      "applyResult: a late transient keeps the prior real failure_type (no downgrade to 'other')",
    );
    eq(
      rLateTransient.verdict.summary,
      "still 3 lint errors in foo.js",
      "applyResult: a late transient keeps the prior real summary (not the generic retry text)",
    );

    // #259 — wrapVerify: a real verify response is tagged agentVerdict:true; a null
    // verify falls back to a transientVerdict that preserves an applied fix's files.
    const realWrap = wrapVerify(
      { fixed: true, failure_type: "lint", summary: "passes", files_changed: ["a.js"], remainingFailures: [] },
      check,
      { failure_type: "lint" },
      { applied: true, files_changed: ["a.js"] },
    );
    eq(realWrap.agentVerdict, true, "wrapVerify: a real verify response is tagged agentVerdict:true");
    eq(realWrap.fixed, true, "wrapVerify: a real verify response passes its fields through");
    const nullWrap = wrapVerify(null, check, { failure_type: "type" }, { applied: true, files_changed: ["b.ts"] });
    eq(nullWrap.agentVerdict, false, "wrapVerify: a null verify falls back to a transient verdict");
    eq(
      JSON.stringify(nullWrap.files_changed),
      JSON.stringify(["b.ts"]),
      "wrapVerify: a null verify preserves the applied fix's files_changed",
    );
  }
}
