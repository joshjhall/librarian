// ship-issue area — argument validation — KNOWN_ARG_KEYS, unknownArgKeys, noDiffSupplied
//
// Split out of tests/workflow-helpers/ship-issue.mjs (#712): the file had grown
// to 1374 production LOC as a single `export async function run()`, past the
// review lens's 800 `high` threshold. Content moved VERBATIM — only the
// indentation and the import depth changed.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, harnessSource, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
// ===========================================================================
// args-contract validation (#597)
//
// Every `args.<key>` read in the harness falls back to an empty default, so a
// MISTYPED key is dropped in silence and the cycle reviews less than the
// caller believes. The #567 instance passed `argsFile` instead of the inline
// inputs: `diff`, `preScan` and `conventionsDigest` all vanished, five
// reviewers ran against an empty diff, and the cycle returned `clean: true`
// — indistinguishable in the output from a real pass, and half the merge
// invariant.
//
// Two kinds of assertion below, and BOTH are needed. The behavioural ones
// prove `unknownArgKeys` classifies correctly; the structural ones prove it is
// actually CALLED and that the call throws. A correct helper that nothing
// invokes passes every behavioural test while the harness stays exactly as
// broken — the tautology shape this repo hit on #599 and #600.
// ===========================================================================
{
  const { KNOWN_ARG_KEYS, unknownArgKeys, noDiffSupplied } = extractHelpers(SHIP, [
    "KNOWN_ARG_KEYS",
    "unknownArgKeys",
    "noDiffSupplied",
  ]);

  // --- The regression that motivated the issue ----------------------------
  // Not just "something was rejected" — the offending key must be NAMED, or
  // the caller cannot tell which of a dozen inputs to fix.
  const argsFileCase = unknownArgKeys({
    phase: "pre-pr",
    cycle: 1,
    argsFile: "/tmp/555-args.json",
  });
  eq(argsFileCase.length, 1, "unknownArgKeys: the #567 argsFile dispatch is rejected");
  eq(argsFileCase[0], "argsFile", "unknownArgKeys: names the offending key (#597 AC#1)");

  // --- No false rejections (AC#2) -----------------------------------------
  // Build the full-contract object FROM the contract itself, so a key added to
  // KNOWN_ARG_KEYS later is automatically exercised here rather than quietly
  // going uncovered.
  const fullContract = {};
  for (const k of KNOWN_ARG_KEYS) fullContract[k] = "x";
  eq(
    unknownArgKeys(fullContract).length,
    0,
    "unknownArgKeys: every documented key is accepted (#597 AC#2)",
  );
  // And the contract is the expected size — a key silently DELETED from
  // KNOWN_ARG_KEYS would start rejecting a legitimate input, which the
  // build-from-contract assertion above cannot catch on its own.
  eq(KNOWN_ARG_KEYS.length, 13, "KNOWN_ARG_KEYS: holds all 13 contract keys");

  // --- All offenders reported, not just the first -------------------------
  // A caller that got two keys wrong should learn both in one dispatch.
  // `token_ceiling` is the realistic second case: the right word in the wrong
  // case convention, which no spell-check would catch and the harness would
  // otherwise drop in silence.
  const multi = unknownArgKeys({ diff: "d", argsFile: "a", token_ceiling: 5 });
  eq(multi.length, 2, "unknownArgKeys: reports every unknown key, not just the first");
  ok(
    multi.includes("argsFile") && multi.includes("token_ceiling"),
    "unknownArgKeys: both offending keys are named",
  );

  // --- Total on the no-input paths ----------------------------------------
  // `args` may legitimately be absent — every read in the harness tolerates
  // that. Validation must not convert the no-input case into a crash.
  for (const [val, label] of [
    [null, "null"],
    [undefined, "undefined"],
    ["a string", "a non-object"],
    [["a", "b"], "an array"],
  ]) {
    eq(unknownArgKeys(val).length, 0, `unknownArgKeys: ${label} args yields no unknown keys`);
  }

  // --- Code/doc sync (BIDIRECTIONAL) --------------------------------------
  // The header comment block is what a caller reads to learn the contract;
  // KNOWN_ARG_KEYS is what the harness enforces. Drift in EITHER direction is
  // a live defect, and they fail differently:
  //
  //   code → doc  (in the array, not in the header): an accepted input no
  //               caller knows to pass.
  //   doc → code  (in the header, not in the array): worse — a caller follows
  //               the documentation, passes the key, and the harness THROWS on
  //               a legitimately documented input.
  //
  // Iterating KNOWN_ARG_KEYS alone only ever catches the first. So parse the
  // header's own key list and compare the two as ordered sequences: that pins
  // both directions at once, and additionally pins the "Order matches the
  // header block" claim the KNOWN_ARG_KEYS comment makes — a claim a
  // membership-only check would leave free to become false.
  const src = harnessSource(SHIP);
  const header = src.slice(src.indexOf("// Input (passed verbatim"), src.indexOf("const KNOWN_ARG_KEYS"));
  // Key lines in the block are indented 4+ spaces after the `//`; the 4-space
  // floor keeps the `// {` / `// }` wrapper and prose lines out.
  const documented = [...header.matchAll(/^\/\/\s{4,}(\w+)\??:/gm)].map((m) => m[1]);
  eq(
    documented.join(","),
    KNOWN_ARG_KEYS.join(","),
    "KNOWN_ARG_KEYS: matches the header comment block exactly, in order (bidirectional sync)",
  );
  // Guard the parse itself: a header reformat that stopped matching the regex
  // would make `documented` empty, and an empty-vs-empty comparison would pass
  // vacuously if KNOWN_ARG_KEYS were ever also empty.
  ok(documented.length >= 13, "KNOWN_ARG_KEYS: the header block actually parsed (not a vacuous match)");

  // --- Structural: the helper is WIRED, not merely defined -----------------
  const boundary = src.match(
    /^(log\(|phase\(|await |const\s+\w+\s*=\s*await\b|let\s+\w+\s*=\s*await\b|if \(|for \(|while \(|return )/m,
  );
  ok(boundary, "ship-issue: orchestration boundary is still findable");
  const callIdx = src.indexOf("unknownArgKeys(args)");
  ok(callIdx !== -1, "ship-issue: unknownArgKeys is actually called on args (#597 wiring)");
  ok(
    callIdx > boundary.index,
    "ship-issue: the unknownArgKeys call sits in the orchestration body, past the extractor boundary",
  );
  // The definition must stay in the PURE prefix, or extractHelpers cannot
  // reach it and every assertion in this block would be testing nothing.
  ok(
    src.indexOf("const unknownArgKeys") < boundary.index,
    "ship-issue: unknownArgKeys is defined in the pure prefix (extractable)",
  );
  // The call site must THROW. A call whose result is logged and discarded
  // would satisfy every assertion above while still merging on a hollow review.
  const callSite = src.slice(callIdx, callIdx + 900);
  ok(
    /throw new Error\(/.test(callSite),
    "ship-issue: an unknown key throws rather than being logged and ignored (#597 AC#1)",
  );
  ok(
    /unknownKeys\.join/.test(callSite),
    "ship-issue: the thrown message interpolates the offending key(s)",
  );

  // --- Behavioural: the no-diff predicate (AC#3) ---------------------------
  // The `log()` this guards sits past ORCH_BOUNDARY and cannot be extracted,
  // so the CONDITION is a pure helper and gets tested directly. A structural
  // source-grep alone would not notice the boolean logic being inverted
  // (`||` for `&&`), which is the mistake that actually breaks this: `||`
  // would warn on every narrowed re-review cycle and train the operator to
  // ignore the line.
  eq(noDiffSupplied("", ""), true, "noDiffSupplied: neither diff nor delta → warn");
  eq(noDiffSupplied("d", ""), false, "noDiffSupplied: a full diff alone → no warning");
  eq(noDiffSupplied("", "d"), false, "noDiffSupplied: a fix delta alone → no warning (narrowed cycle)");
  eq(noDiffSupplied("d", "d"), false, "noDiffSupplied: both present → no warning");

  // --- Structural: the no-diff check is wired ------------------------------
  const noDiffIdx = src.indexOf("if (noDiffSupplied(scopeDiff, deltaDiff))");
  ok(noDiffIdx !== -1, "ship-issue: a cycle with neither diff nor deltaDiff is detected (#597 AC#3)");
  ok(noDiffIdx > boundary.index, "ship-issue: the no-diff check is in the orchestration body");
  ok(
    /WARNING/.test(src.slice(noDiffIdx, noDiffIdx + 400)),
    "ship-issue: the no-diff cycle is surfaced as a WARNING, not silently reviewed",
  );
}
}
