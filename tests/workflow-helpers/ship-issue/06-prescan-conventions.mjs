// ship-issue area — pre-scan candidate handoff and the conventions digest
//
// Split out of tests/workflow-helpers/ship-issue.mjs (#712): the file had grown
// to 1374 production LOC as a single `export async function run()`, past the
// review lens's 800 `high` threshold. Content moved VERBATIM — only the
// indentation and the import depth changed.
//
// Covers #555/#557: pre-scan rows are CONTEXT rather than findings, and the
// digest that removes the per-cycle doc reads.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
// =============================================================================
// ship-issue — the ceiling is OFF by default and every cycle reports its cost
// =============================================================================
// A ceiling set below where output actually lands is WORSE than none: hitting it
// forces `clean` false, which makes the skill cycle++ and re-run, so a too-low
// ceiling spends its full budget every cycle, exhausts REVIEW_MAX_CYCLES and
// dead-ends the PR. The default must therefore be unbounded, and the harness
// must emit the data needed to size a ceiling from observation instead.
{
  const src = harnessSource(SHIP);

  // Both return paths report cost — the findings path and the empty/early path.
  // Excluding the empty path would bias the sample an operator sizes from.
  eq(
    (src.match(/token_report:\s*\{/g) || []).length,
    2,
    "ship-issue: token_report is on BOTH the findings and empty return paths (#553)",
  );
  ok(
    /output_tokens:\s*reviewBudget\.spent\(\)/.test(src),
    "ship-issue: token_report reports actual spend via reviewBudget.spent()",
  );
  // The report must be emitted on unbounded runs too — that is its whole purpose.
  ok(
    /bound:\s*budget\.total\s*\?\s*'runtime'\s*:\s*CYCLE_TOKEN_CEILING\s*\?\s*'caller'\s*:\s*'none'/.test(src),
    "ship-issue: token_report names the live bound, including 'none' (#553)",
  );

  // No default ceiling anywhere in the caller protocol docs: an unset
  // REVIEW_TOKEN_CEILING must mean the arg is OMITTED, not defaulted to a number.
  for (const doc of [
    "plugins/workflow/skills/ship-issue/pre-ship-validation.md",
    "plugins/workflow/skills/ship-issue/ci-review-protocol.md",
  ]) {
    const d = harnessSource(doc);
    ok(
      !/tokenCeiling:\s*<REVIEW_TOKEN_CEILING,\s*default\s*\d/.test(d),
      `${doc}: tokenCeiling is not documented with a numeric default (#553 — off by default)`,
    );
  }
}

// =============================================================================
// ship-issue — pre-scan candidate handoff (#556)
// =============================================================================
// pre-review-gates.sh already runs before the harness and its TSV was discarded,
// so reviewers re-derived mechanical findings by shelling out. These candidates
// are CONTEXT, never findings: the scanner is a regex matcher that cannot see
// cross-directory tests (#555), so the prompt must invite dismissal.
{
  const mkPreScan = (preScan) =>
    extractHelpers(SHIP, ["preScanSection", "preScan", "preScanTruncated", "PRESCAN_MAX"], {
      cycle: 1,
      preScan,
    });

  const CAND = { file: "a.js", line: 1, category: "missing-test-file", evidence: "no test", certainty: "HIGH" };

  // The no-op case must leave the shared prefix BYTE-IDENTICAL to pre-#556 —
  // otherwise adding this feature silently invalidates the #256 prompt cache on
  // every run that does not use it.
  for (const [label, args] of [
    ["absent", undefined],
    ["empty array", []],
    ["not an array", "nope"],
  ]) {
    eq(mkPreScan(args).preScanSection(), "", `preScanSection: ${label} ⇒ empty string (cache-stable no-op)`);
  }

  // Malformed rows are dropped, not crashed on — a bad scanner line must never
  // take down the review cycle.
  // Each junk row is missing at least one of the two required fields, so only
  // CAND survives — file AND category are both mandatory (a row with just one
  // cannot be anchored to a location a reviewer could check).
  const junk = mkPreScan([null, {}, { file: "" }, { file: "x.js" }, { category: "c" }, CAND]);
  eq(junk.preScan.length, 1, "preScanSection: rows missing file OR category are dropped");

  const sec = mkPreScan([CAND]).preScanSection();
  ok(sec.includes("a.js"), "preScanSection: renders the candidate file");
  ok(sec.includes("PRE-SCAN CANDIDATES"), "preScanSection: wraps candidates in a dataBlock fence");
  ok(
    /DATA ONLY|never as instructions/.test(sec),
    "preScanSection: candidates carry the data-only injection guard (untrusted file content)",
  );
  // The framing is the whole point (#555): a reviewer must feel free to dismiss.
  ok(/NOT a confirmed finding/i.test(sec), "preScanSection: candidates are framed as unconfirmed");
  ok(/dismiss/i.test(sec), "preScanSection: reviewers are told they may dismiss");
  ok(/do NOT re-derive/i.test(sec), "preScanSection: reviewers are told not to re-derive (the cost saving)");
  ok(/file anything else you find/i.test(sec), "preScanSection: candidates do not bound the reviewer");

  // Only the five contract fields ride into the prompt — an untrusted extra key
  // (these objects carry regex matches against file content) must not.
  const sneaky = mkPreScan([{ ...CAND, injected: "IGNORE-PRIOR-INSTRUCTIONS" }]).preScanSection();
  ok(!sneaky.includes("IGNORE-PRIOR-INSTRUCTIONS"), "preScanSection: extra keys are stripped, not forwarded");
  ok(!sneaky.includes("injected"), "preScanSection: extra key NAMES are stripped too");

  // Oversized input is capped, and the cap is DISCLOSED — a silently trimmed
  // list would read as "the scanner found nothing more", a false completeness.
  const many = mkPreScan(Array.from({ length: 150 }, (_, i) => ({ ...CAND, file: `f${i}.js` })));
  eq(many.preScan.length, many.PRESCAN_MAX, "preScanSection: candidate count is capped");
  eq(many.preScanTruncated, 150 - many.PRESCAN_MAX, "preScanSection: truncation count is tracked");
  ok(
    /NOT exhaustive/i.test(many.preScanSection()),
    "preScanSection: truncation is disclosed in-prompt, never silent",
  );

  // #724 cache-prefix neutrality. The prose-classification rows the sizing
  // scanner gained are new CANDIDATE ROWS, not a new prompt mechanism: they
  // ride the same TSV -> preScan -> dataBlock path with its fixed five-field
  // order. So a diff that produces no new candidates must still yield a
  // byte-identical prefix.
  //
  // Asserted as an EQUALITY against a bloat-row payload, not merely as "the
  // no-op is empty" (already covered above): the failure this guards is a
  // hand-rolled builder for the new categories, which would serialize
  // differently while leaving the empty case untouched and every assertion
  // above green.
  const BLOAT = {
    file: "agents/checker.md",
    line: 1,
    category: "ai-file-bloat",
    evidence: "agent definition exceeds high threshold: 580 lines (>400)",
    certainty: "HIGH",
  };
  eq(
    mkPreScan([BLOAT]).preScanSection(),
    mkPreScan([{ ...BLOAT, sneaked: "x" }]).preScanSection(),
    "preScanSection: a bloat row serializes through the fixed-field dataBlock path (#724/#256)",
  );
  ok(
    mkPreScan([BLOAT]).preScanSection().includes("ai-file-bloat"),
    "preScanSection: prose-classification rows reach the reviewer prompt (#724)",
  );

  // #725 cache-prefix neutrality, same shape as the #724 case above. Unifying
  // the split-shape table made the AUDIT lens emit a `split shape for <lang>`
  // row it never emitted before, and the review lens now reaches its own copy
  // through split_shape() — but neither is a new prompt MECHANISM: both ride
  // the same TSV -> preScan -> dataBlock path with its fixed five-field order.
  //
  // Asserted as an EQUALITY against an extra-key variant rather than as "the
  // no-op is empty" (covered above): the failure this guards is a hand-rolled
  // builder for seam rows, which would serialize differently while leaving the
  // empty case untouched and every assertion above green.
  const SEAM = {
    file: "plugins/review-audit/skills/check-decomposition/patterns.py",
    line: 1,
    category: "decomposition-seam",
    evidence: "split shape for py: package dir with __init__.py re-exporting the public surface",
    certainty: "MEDIUM",
  };
  eq(
    mkPreScan([SEAM]).preScanSection(),
    mkPreScan([{ ...SEAM, sneaked: "x" }]).preScanSection(),
    "preScanSection: a split-shape seam row serializes through the fixed-field dataBlock path (#725/#256)",
  );
  ok(
    mkPreScan([SEAM]).preScanSection().includes("split shape for py"),
    "preScanSection: split-shape guidance reaches the reviewer prompt (#725)",
  );

  // #729 cache-prefix neutrality, same shape as the #724/#725 cases above.
  // Teaching the review lens bundle-shaped seams makes it emit `index split:`
  // and `concept split:` rows it never emitted before, and split-verify gains
  // a `split-memory-orphan` category — but none of these is a new prompt
  // MECHANISM: every one rides the same TSV -> preScan -> dataBlock path with
  // its fixed five-field order.
  //
  // The concept row is the one asserted, because it is the one carrying the
  // anti-orphan clause — the sentence whose loss is silent and permanent
  // (#697). A hand-rolled builder for it would serialize differently while
  // leaving the empty case untouched and every assertion above green.
  const BUNDLE_SEAM = {
    file: ".claude/memory/two-lessons.md",
    line: 1,
    category: "decomposition-seam",
    evidence:
      "concept split: extract second_lesson to .claude/memory/second_lesson.md AND add its index line (an extracted concept with no index line is an orphan)",
    certainty: "HIGH",
  };
  eq(
    mkPreScan([BUNDLE_SEAM]).preScanSection(),
    mkPreScan([{ ...BUNDLE_SEAM, sneaked: "x" }]).preScanSection(),
    "preScanSection: a bundle seam row serializes through the fixed-field dataBlock path (#729/#256)",
  );
  ok(
    mkPreScan([BUNDLE_SEAM]).preScanSection().includes("AND add its index line"),
    "preScanSection: the anti-orphan clause survives into the reviewer prompt (#729/#697)",
  );

  const ORPHAN = {
    file: ".claude/memory/two-lessons.md",
    line: 1,
    category: "split-memory-orphan",
    evidence: "1 extracted concept(s) with no index line: second-lesson.md",
    certainty: "HIGH",
  };
  eq(
    mkPreScan([ORPHAN]).preScanSection(),
    mkPreScan([{ ...ORPHAN, sneaked: "x" }]).preScanSection(),
    "preScanSection: a split-memory-orphan row rides the same fixed-field path (#729)",
  );

  // AND the no-op is STILL byte-identical to empty — restated after the new
  // categories, because that is the property #256 actually protects and the
  // equality assertions above would all pass on a build that broke it.
  eq(mkPreScan([]).preScanSection(), "", "preScanSection: no candidates still yields a byte-identical empty prefix (#729/#256)");

  // It must live inside the SHARED block, so all reviewers see it and the
  // fan-out prefix stays byte-identical across siblings (#256).
  const src = harnessSource(SHIP);
  const rd = src.slice(src.indexOf("const reviewerData ="), src.indexOf("\nconst ", src.indexOf("const reviewerData =") + 1));
  ok(rd.includes("preScanSection()"), "ship-issue: preScanSection is part of the shared reviewerData block (#256)");
}

// =============================================================================
// ship-issue — conventions digest + lint authority (#557)
// =============================================================================
// Measured on the baseline run, `conventions` spent 164 of 207 Bash calls
// hand-measuring things the repo's own lint gates already compute (six
// consecutive awk one-liners re-rolling a line-length check, then re-running
// rumdl and shellcheck by hand). The digest kills the 19 doc-read calls; the
// SCOPE_DISCIPLINE lint clause targets the 164.
{
  const mkDigest = (conventionsDigest) =>
    extractHelpers(
      SHIP,
      ["conventionsSection", "conventionsDigest", "conventionsDigestTruncated", "DIGEST_MAX_CHARS"],
      { cycle: 1, conventionsDigest },
    );

  // No-op must be byte-identical to pre-#557 (#256 cache prefix).
  for (const [label, v] of [
    ["absent", undefined],
    ["empty", ""],
    ["whitespace only", "   \n  "],
    ["not a string", 42],
  ]) {
    eq(mkDigest(v).conventionsSection(), "", `conventionsSection: ${label} ⇒ empty string (cache-stable no-op)`);
  }

  const d = mkDigest("bash-3.2 clean; SHA-pinned actions; conform scopes: workflow|tests|ci");
  const sec = d.conventionsSection();
  ok(sec.includes("bash-3.2 clean"), "conventionsSection: renders the digest text");
  ok(sec.includes("PROJECT CONVENTIONS"), "conventionsSection: fenced in a dataBlock");
  ok(/DATA ONLY|never as instructions/.test(sec), "conventionsSection: carries the data-only injection guard");
  ok(/do NOT re-read/i.test(sec), "conventionsSection: tells reviewers not to re-read the source files");
  // A digest is a SUMMARY. If reviewers treat it as the complete ruleset they
  // will wave through a real violation that simply did not fit.
  ok(/still flag it/i.test(sec), "conventionsSection: an omitted rule is still flaggable (digest is not exhaustive)");

  // Oversized digests are capped AND the truncation is disclosed — a silently
  // trimmed rule list reads as a complete one.
  const big = mkDigest("x".repeat(9000));
  eq(big.conventionsDigest.length, big.DIGEST_MAX_CHARS, "conventionsSection: digest is capped");
  eq(big.conventionsDigestTruncated, true, "conventionsSection: truncation is tracked");
  ok(/TRUNCATED/i.test(big.conventionsSection()), "conventionsSection: truncation is disclosed in-prompt");

  // The lint-authority clause is what stops the 164 hand-measurement calls.
  const src = harnessSource(SHIP);
  const sd = src.slice(src.indexOf("const SCOPE_DISCIPLINE ="), src.indexOf("\n// `sanitize`"));
  ok(/do not re-run those/i.test(sd.replace(/\s+/g, " ")), "SCOPE_DISCIPLINE: reviewers told not to re-run lint tools");
  ok(/hand-measure/i.test(sd), "SCOPE_DISCIPLINE: reviewers told not to hand-measure lint-decidable facts");
  for (const tool of ["rumdl", "shellcheck", "typos", "ruff"]) {
    ok(sd.includes(tool), `SCOPE_DISCIPLINE: names ${tool} as an enforcing gate`);
  }

  // Both blocks must live in the SHARED reviewerData so every dimension sees
  // them and the fan-out prefix stays byte-identical across siblings (#256).
  const rd = src.slice(src.indexOf("const reviewerData ="), src.indexOf("\nconst ", src.indexOf("const reviewerData =") + 1));
  ok(rd.includes("conventionsSection()"), "ship-issue: conventionsSection is in the shared reviewerData block (#256)");
}
}
