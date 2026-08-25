// ship-issue area — the #260 TDZ regression and #267's diffSection
//
// Split out of tests/workflow-helpers/ship-issue.mjs (#712): the file had grown
// to 1374 production LOC as a single `export async function run()`, past the
// review lens's 800 `high` threshold. Content moved VERBATIM — only the
// indentation and the import depth changed.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { ok } from "../../lib/mjs-assert.mjs";
import { extractHelpers, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
// #260 regression: the scope-drift dimension in NEW_DIMENSIONS calls
// `sanitize(issue.title)` at MODULE LOAD when an `issue` is provided. If
// `sanitize`/`dataBlock` were defined AFTER NEW_DIMENSIONS (their original,
// buggy placement), the prefix would throw "Cannot access 'sanitize' before
// initialization" (a temporal dead zone) — but only on the branch where `issue`
// is truthy, which the assertions above never hit. Extracting with an `issue`
// present forces that branch to evaluate during prefix load, so a helper defined
// too late makes extractHelpers throw here. This must NOT throw.
{
  let helpers;
  ok(
    (() => {
      try {
        helpers = extractHelpers(SHIP, ["sanitize", "dataBlock"], {
          cycle: 1,
          phase: "pre-pr",
          files: ["x.js"],
          issue: { number: 260, title: "Title\nwith newline" },
        });
        return true;
      } catch {
        return false;
      }
    })(),
    "ship-issue: prefix loads with an issue present — sanitize/dataBlock precede NEW_DIMENSIONS (no TDZ, #260)",
  );
  ok(
    helpers && typeof helpers.sanitize === "function" && typeof helpers.dataBlock === "function",
    "ship-issue: sanitize + dataBlock are live after an issue-present load (#260)",
  );
}

// #267: ship-issue's diffSection mirrors code-reviewer's but derives against
// origin/main...HEAD on the no-diff fallback. Same guarantees: byte-faithful
// pass-through when supplied, deliberate in-agent derive when not.
{
  const withDiff = extractHelpers(SHIP, ["diffSection"], {
    diff: "SHIP-BYTE-FAITHFUL-QRS",
  });
  ok(
    withDiff.diffSection().includes("SHIP-BYTE-FAITHFUL-QRS"),
    "diffSection (ship-issue): supplied diff bytes pass through verbatim",
  );
  ok(
    !/derive it yourself/.test(withDiff.diffSection()),
    "diffSection (ship-issue): no derive instruction when a diff is supplied",
  );
  const noDiff = extractHelpers(SHIP, ["diffSection"], {});
  ok(
    /derive it yourself/.test(noDiff.diffSection()),
    "diffSection (ship-issue): no-diff path instructs in-agent derivation",
  );
  ok(
    noDiff.diffSection().includes("git diff origin/main...HEAD"),
    "diffSection (ship-issue): no-diff path names git diff origin/main...HEAD",
  );

  // #267: the manifest no longer transcribes the diff — MANIFEST_SCHEMA must not
  // require or define `diff`.
  const { MANIFEST_SCHEMA } = extractHelpers(SHIP, ["MANIFEST_SCHEMA"]);
  ok(
    !MANIFEST_SCHEMA.required.includes("diff"),
    "MANIFEST_SCHEMA (ship-issue): diff dropped from required",
  );
  ok(
    !("diff" in MANIFEST_SCHEMA.properties),
    "MANIFEST_SCHEMA (ship-issue): diff dropped from properties",
  );

  // #267: wire-test all three reviewer/comment prompt builders that splice in the
  // diff. Each must carry the caller's bytes and never a stray `undefined` from a
  // reverted `manifest.diff` embed. commentsPrompt reads module-level prComments
  // (derived from args at prefix load), so seed it alongside the diff.
  const builders = extractHelpers(
    SHIP,
    ["reusedReviewerPrompt", "newReviewerPrompt", "commentsPrompt"],
    { diff: "SHIP-BYTE-FAITHFUL-QRS", prComments: [{ id: "c1", body: "x" }] },
  );
  const manifest = {
    files: ["a.js"],
    classifications: [{ file: "a.js", types: ["source"] }],
    needs: { database: false, devops: false },
  };
  const prompts = {
    reusedReviewerPrompt: builders.reusedReviewerPrompt(
      { mode: "security", category: "security" },
      manifest,
    ),
    newReviewerPrompt: builders.newReviewerPrompt(
      { name: "tests", category: "tests", instructions: "inline" },
      manifest,
    ),
    commentsPrompt: builders.commentsPrompt(manifest),
  };
  for (const [name, prompt] of Object.entries(prompts)) {
    ok(
      prompt.includes("SHIP-BYTE-FAITHFUL-QRS"),
      `${name} (ship-issue): splices the caller's diff bytes into the prompt`,
    );
    ok(
      !prompt.includes("undefined"),
      `${name} (ship-issue): no stray \`undefined\` from a manifest.diff regression`,
    );
  }
}
}
