// ship-issue area — the #492 re-review narrowing selector
//
// Split out of tests/workflow-helpers/ship-issue.mjs (#712): the file had grown
// to 1374 production LOC as a single `export async function run()`, past the
// review lens's 800 `high` threshold. Content moved VERBATIM — only the
// indentation and the import depth changed.
//
// Assertions are collect-all (they record, never throw) — see tests/lib/mjs-assert.mjs.

import { readFileSync } from "node:fs";
import { join } from "node:path";

import { ok, eq } from "../../lib/mjs-assert.mjs";
import { extractHelpers, repoRoot, SHIP } from "../../lib/extract-helpers.mjs";

export async function run() {
// #492: re-review narrowing. The selector decides which dimensions run on a
// re-review cycle and the diff each one reads — the delta-local dimensions
// (security/correctness/tests) narrow to the fix-commit delta, while
// scope-drift always reads the full diff (its AC-completeness check is a
// whole-change lens). Extracted (like computeClean/applyJudgeVerdicts) so the
// narrowing decision is testable without executing the harness. The budget stub
// below reports `total: null` so no dimension is budget-floor skipped — narrowing
// is isolated from the budget path.
{
  const {
    narrowingActive,
    dimensionTouchesDelta,
    manifestTypeSet,
    selectReviewDimensions,
    includeSpecialist,
    diffForInclusion,
    REUSED_DIMENSIONS,
    NEW_DIMENSIONS,
    DIMENSION_RELEVANT_TYPES,
  } = extractHelpers(
    SHIP,
    [
      "narrowingActive",
      "dimensionTouchesDelta",
      "manifestTypeSet",
      "selectReviewDimensions",
      "includeSpecialist",
      "diffForInclusion",
      "REUSED_DIMENSIONS",
      "NEW_DIMENSIONS",
      "DIMENSION_RELEVANT_TYPES",
    ],
    { cycle: 2, phase: "pr-cycle", files: ["x.js"] },
  );

  // narrowingActive: on cycle 1 or without a non-empty delta diff+files, narrowing
  // is OFF (full review) — the delta args are additive and default-off.
  eq(narrowingActive(1, "d", ["a.js"]), false, "narrowingActive: cycle 1 never narrows");
  eq(narrowingActive(2, "", ["a.js"]), false, "narrowingActive: empty deltaDiff does not narrow");
  eq(narrowingActive(2, "d", []), false, "narrowingActive: empty deltaFiles does not narrow");
  eq(narrowingActive(2, "d", ["a.js"]), true, "narrowingActive: cycle>1 with a real delta narrows");

  // dimensionTouchesDelta: the delta-relevance table. security/correctness key off
  // source|database|config (config carries secrets + config-driven logic bugs);
  // tests off source|test; an unknown dimension is never relevant.
  //
  // #551 — the '*' WILDCARD BRANCH. `conventions` was the table's only wildcard
  // entry and was demoted out of the fan-out, so no production entry reaches
  // `relevant.includes('*')` today. The branch is deliberately KEPT (it is a
  // general mechanism of the table, not a fact about that one dimension), which
  // means it can only be exercised through a synthetic entry — done here rather
  // than left untested, since an unreachable-from-production branch with no test
  // at all is how a future all-types dimension inherits a silently broken one.
  // Asserted against BOTH a type in the table and one absent from it, so a
  // regression to `relevant.includes(type)` fails rather than coincidentally
  // passing.
  eq(
    Object.values(DIMENSION_RELEVANT_TYPES).filter((v) => v.includes("*")).length,
    0,
    "DIMENSION_RELEVANT_TYPES: no production dimension uses the '*' wildcard after the #551 demotion",
  );
  {
    const saved = DIMENSION_RELEVANT_TYPES["__synthetic_wildcard__"];
    DIMENSION_RELEVANT_TYPES["__synthetic_wildcard__"] = ["*"];
    eq(
      dimensionTouchesDelta("__synthetic_wildcard__", new Set(["config"])),
      true,
      "dimensionTouchesDelta: a '*' entry matches a type the table knows",
    );
    eq(
      dimensionTouchesDelta("__synthetic_wildcard__", new Set(["not-a-real-type"])),
      true,
      "dimensionTouchesDelta: a '*' entry matches a type the table has never heard of (true wildcard, not a lookup)",
    );
    if (saved === undefined) delete DIMENSION_RELEVANT_TYPES["__synthetic_wildcard__"];
    else DIMENSION_RELEVANT_TYPES["__synthetic_wildcard__"] = saved;
  }
  eq(dimensionTouchesDelta("security", new Set(["source"])), true, "dimensionTouchesDelta: security touches source");
  eq(dimensionTouchesDelta("security", new Set(["config"])), true, "dimensionTouchesDelta: security touches config (secrets / insecure settings)");
  eq(dimensionTouchesDelta("correctness", new Set(["config"])), true, "dimensionTouchesDelta: correctness touches config (config-driven logic bugs)");
  eq(dimensionTouchesDelta("security", new Set(["test"])), false, "dimensionTouchesDelta: security ignores a test-only delta");
  eq(dimensionTouchesDelta("tests", new Set(["test"])), true, "dimensionTouchesDelta: tests touches test files");
  eq(dimensionTouchesDelta("tests", new Set(["config"])), false, "dimensionTouchesDelta: tests ignores a config-only delta");
  // #529: ci/docker are relevant to the GENERIC security + correctness dimensions.
  // The devops specialist also runs on such a delta (gated on manifest.needs), but
  // its checklist is infrastructure-shaped — no OWASP lens, no correctness lens —
  // so these entries are the only thing keeping a docker/CI-only fix delta from
  // dropping both generic dimensions.
  eq(dimensionTouchesDelta("security", new Set(["docker"])), true, "dimensionTouchesDelta: security touches docker (#529 — devops does not carry the OWASP lens)");
  eq(dimensionTouchesDelta("security", new Set(["ci"])), true, "dimensionTouchesDelta: security touches ci (#529 — credential handling in CI scripts)");
  eq(dimensionTouchesDelta("correctness", new Set(["docker"])), true, "dimensionTouchesDelta: correctness touches docker (#529 — devops has no correctness lens)");
  eq(dimensionTouchesDelta("correctness", new Set(["ci"])), true, "dimensionTouchesDelta: correctness touches ci (#529 — logic bugs in CI conditionals)");
  // tests stays deliberately narrow — pins the scope of #529 so a future
  // widen-everything edit trips here rather than silently inflating every cycle.
  eq(dimensionTouchesDelta("tests", new Set(["docker"])), false, "dimensionTouchesDelta: tests ignores a docker-only delta (#529 scope is security/correctness only)");
  eq(dimensionTouchesDelta("tests", new Set(["ci"])), false, "dimensionTouchesDelta: tests ignores a ci-only delta (#529 scope is security/correctness only)");
  eq(dimensionTouchesDelta("scope-drift", new Set(["source"])), false, "dimensionTouchesDelta: scope-drift is not delta-gated (handled separately)");
  eq(dimensionTouchesDelta("nonexistent", new Set(["source"])), false, "dimensionTouchesDelta: an unrecognized dimension name fails closed (never relevant)");

  // manifestTypeSet: flatten classifications into the set of present types.
  const typeSet = manifestTypeSet({ classifications: [{ file: "a.py", types: ["source"] }, { file: "m.sql", types: ["database", "source"] }] });
  ok(typeSet.has("source") && typeSet.has("database") && typeSet.size === 2, "manifestTypeSet: unions all classified types");

  const budgetOff = { total: null, remaining: () => Infinity, spent: () => 0 };
  const fullDiff = "FULL-DIFF";
  const deltaDiff = "DELTA-DIFF";
  const call = (opts) =>
    selectReviewDimensions({
      cycle: 2,
      fullDiff,
      deltaDiff,
      deltaFiles: ["a.py"],
      priorBlocking: [],
      manifest: { classifications: [{ file: "a.py", types: ["source"] }] },
      budget: budgetOff,
      budgetFloor: 40000,
      reusedDimensions: REUSED_DIMENSIONS,
      newDimensions: NEW_DIMENSIONS,
      ...opts,
    });

  // Full cycle (cycle 1): every dimension runs, every entry reads the FULL diff.
  const full = call({ cycle: 1 });
  const fullNames = full.entries.map((e) => e.dim.name).sort();
  eq(
    JSON.stringify(fullNames),
    JSON.stringify(["correctness", "decomposition", "scope-drift", "security", "tests"]),
    "selectReviewDimensions: full cycle runs every dimension",
  );
  ok(full.entries.every((e) => e.diff === fullDiff), "selectReviewDimensions: full cycle every entry reads the full diff");
  eq(full.narrowed, false, "selectReviewDimensions: cycle 1 is not narrowed");
  eq(full.budgetExhausted, false, "selectReviewDimensions: full cycle not budget-exhausted");
  eq(full.dimensionsSkipped.length, 0, "selectReviewDimensions: full cycle skips nothing");

  // Budget-floor branch: when the shared budget is below the floor, every NEW
  // dimension (tests/decomposition/scope-drift) is skipped into dimensionsSkipped and
  // budgetExhausted flips true — the genuine partial-cycle signal (distinct from a
  // narrowing drop). Reused dimensions (security/correctness) have no budget gate.
  const lowBudget = { total: 100000, remaining: () => 1000, spent: () => 99000 };
  const starved = call({ cycle: 1, budget: lowBudget });
  eq(starved.budgetExhausted, true, "selectReviewDimensions: sub-floor budget flips budgetExhausted true");
  eq(
    JSON.stringify(starved.dimensionsSkipped.sort()),
    JSON.stringify(["decomposition", "scope-drift", "tests"]),
    "selectReviewDimensions: sub-floor budget skips every NEW dimension into dimensionsSkipped",
  );
  eq(
    JSON.stringify(starved.entries.map((e) => e.dim.name).sort()),
    JSON.stringify(["correctness", "security"]),
    "selectReviewDimensions: only the budget-gate-free reused dimensions survive a sub-floor budget",
  );

  // Missing delta on cycle > 1 ⇒ non-narrowed fallback (same as cycle 1).
  const noDelta = call({ deltaDiff: "" });
  eq(noDelta.narrowed, false, "selectReviewDimensions: cycle>1 without a delta falls back to full");
  eq(noDelta.entries.length, 5, "selectReviewDimensions: fallback runs all five dimensions");
  ok(noDelta.entries.every((e) => e.diff === fullDiff), "selectReviewDimensions: fallback reads the full diff");

  // Narrowed, source-only delta: security/correctness/tests/decomposition
  // all touch source and run against the DELTA diff; scope-drift always runs against
  // the FULL diff. (Here every delta-local dim happens to be relevant, so all five
  // appear — the drop case is asserted next.)
  const src = call({});
  eq(src.narrowed, true, "selectReviewDimensions: source-delta cycle is narrowed");
  const byName = Object.fromEntries(src.entries.map((e) => [e.dim.name, e]));
  eq(byName["scope-drift"].diff, fullDiff, "selectReviewDimensions: scope-drift ALWAYS reads the full diff (Fork A)");
  eq(byName["security"].diff, deltaDiff, "selectReviewDimensions: delta-local security reads the delta diff");
  eq(byName["tests"]?.diff, deltaDiff, "selectReviewDimensions: delta-local tests reads the delta diff");
  eq(src.budgetExhausted, false, "selectReviewDimensions: narrowing does not force budget_exhausted");
  eq(src.dimensionsSkipped.length, 0, "selectReviewDimensions: narrowing does not populate dimensions_skipped");

  // Narrowed, config-only delta: security + correctness NOW touch config (secrets /
  // config-driven bugs), so they run against the delta; tests does NOT touch config
  // and did not block ⇒ DROPPED; decomposition drops too (config is not a
  // decomposition candidate). scope-drift always runs. Since the #551 demotion of
  // `conventions` there is no wildcard dimension propping this list up: every name
  // below is here because its OWN type row matched, which is what the case tests.
  const cfg = call({
    deltaFiles: ["config.yaml"],
    manifest: { classifications: [{ file: "config.yaml", types: ["config"] }] },
  });
  const cfgNames = cfg.entries.map((e) => e.dim.name).sort();
  eq(
    JSON.stringify(cfgNames),
    JSON.stringify(["correctness", "scope-drift", "security"]),
    "selectReviewDimensions: config-only delta keeps security/correctness (config is relevant), drops tests + decomposition",
  );
  eq(cfg.dimensionsSkipped.length, 0, "selectReviewDimensions: a narrowing DROP is not a partial-cycle signal");
  eq(cfg.budgetExhausted, false, "selectReviewDimensions: a narrowing DROP does not force budget_exhausted");

  // #695 — the `decomposition` dimension's own narrowing behavior. The three
  // properties are asserted SEPARATELY rather than being left implicit in the
  // dimension-name lists above, because each can regress independently:
  //
  //   (a) it DROPS on a config-only delta. A .json/.yaml/Dockerfile is not a
  //       decomposition candidate — the scanner skips those extensions outright
  //       — so running it there would spend a reviewer on a delta it can say
  //       nothing about. This is the entry that distinguishes its relevant-types
  //       row from security/correctness, so a copy-paste of their row (the
  //       obvious wrong edit) fails HERE.
  eq(
    cfg.entries.some((e) => e.dim.name === "decomposition"),
    false,
    "selectReviewDimensions: config-only delta drops decomposition (config files are not sizeable) (#695)",
  );

  //   (b) it RUNS on a docs-only delta, reading the DELTA diff. Prose is this
  //       repo's largest and fastest-churning surface (#589) and the markdown
  //       progressive-disclosure case is where the dimension is least redundant,
  //       so a `docs` type dropping out of its row is a real coverage loss.
  //       `?.diff` (not a bare `.diff`) so a missing entry RECORDS a failure
  //       instead of throwing and aborting the collect-all run.
  // THE FIXTURE BELOW HAND-BUILDS A MANIFEST, so on its own it proves only
  // that the selector reacts to a `docs` type IF one arrives — not that the
  // upstream manifest agent ever emits one. That gap was real: `docs` was
  // absent from code-reviewer.md's Step 2 classification table, so a
  // markdown-only delta classified as NO type at all and the decomposition
  // dimension was silently dropped on exactly the case it exists for.
  //
  // So assert the two ends agree. This is a cross-artifact check — the
  // selector's relevant-types row lives in workflow.js, the vocabulary that
  // can satisfy it lives in a different plugin's agent prose — and nothing
  // else in the suite spans that boundary. Without it, a future edit dropping
  // `docs` from the table restores a dead code path with every test green.
  const reviewerAgent = readFileSync(
    join(repoRoot, "plugins/dev-core/agents/code-reviewer.md"),
    "utf8",
  );
  for (const t of DIMENSION_RELEVANT_TYPES.decomposition) {
    ok(
      new RegExp(`^\\|\\s*${t}\\s*\\|`, "m").test(reviewerAgent),
      `DIMENSION_RELEVANT_TYPES.decomposition type '${t}' is a real manifest type in code-reviewer.md Step 2 (#695)`,
    );
  }

  const docsOnly = call({
    deltaFiles: ["docs/guide.md"],
    manifest: { classifications: [{ file: "docs/guide.md", types: ["docs"] }] },
  });
  const docsByName = Object.fromEntries(docsOnly.entries.map((e) => [e.dim.name, e]));
  eq(
    docsByName["decomposition"]?.diff,
    deltaDiff,
    "selectReviewDimensions: docs-only delta RUNS decomposition against the delta diff (#589/#695)",
  );

  //   (c) the prior-blocking carry-over reaches it: a decomposition finding
  //       whose fix touched only config must still be re-confirmed, and against
  //       the FULL diff — the finding it re-checks may live outside the fix
  //       delta. Without this, a size finding could silently vanish from
  //       `blocking` and read as resolved.
  const decompPrior = call({
    deltaFiles: ["config.yaml"],
    manifest: { classifications: [{ file: "config.yaml", types: ["config"] }] },
    priorBlocking: ["decomposition"],
  });
  const priorByName = Object.fromEntries(decompPrior.entries.map((e) => [e.dim.name, e]));
  eq(
    priorByName["decomposition"]?.diff,
    fullDiff,
    "selectReviewDimensions: prior-blocking decomposition re-runs against the FULL diff even on an irrelevant delta (#695)",
  );

  // #529 — narrowed, docker-only delta: before the fix, security + correctness both
  // dropped here (neither listed `docker`), leaving coverage solely to the `devops`
  // specialist, whose checklist carries no OWASP and no correctness lens. Now both
  // run — and CRUCIALLY against the DELTA diff, i.e. via the `touched` path, not the
  // full-diff prior-blocking carry-over (priorBlocking is empty here), so the #492
  // saving keeps its shape. `tests` and `decomposition` still drop (docker is in
  // neither row).
  const dockerOnly = call({
    deltaFiles: ["Dockerfile"],
    manifest: { classifications: [{ file: "Dockerfile", types: ["docker"] }] },
  });
  eq(
    JSON.stringify(dockerOnly.entries.map((e) => e.dim.name).sort()),
    JSON.stringify(["correctness", "scope-drift", "security"]),
    "selectReviewDimensions: docker-only delta keeps generic security/correctness (#529), drops tests + decomposition",
  );
  // `?.diff` (not a bare `.diff`): if the entry is missing — exactly the #529
  // regression — the lookup must RECORD a failure, not throw a TypeError that
  // aborts the whole collect-all run before the remaining assertions execute.
  const dockerByName = Object.fromEntries(dockerOnly.entries.map((e) => [e.dim.name, e]));
  eq(dockerByName["security"]?.diff, deltaDiff, "selectReviewDimensions: docker-only security reads the DELTA diff (touched path, not the prior-blocking full-diff path)");
  eq(dockerByName["correctness"]?.diff, deltaDiff, "selectReviewDimensions: docker-only correctness reads the DELTA diff (touched path)");
  eq(dockerOnly.dimensionsSkipped.length, 0, "selectReviewDimensions: docker-only delta is not a partial cycle");

  // Same for a CI-only delta (workflow files, Jenkinsfile).
  const ciOnly = call({
    deltaFiles: [".github/workflows/ci.yml"],
    manifest: { classifications: [{ file: ".github/workflows/ci.yml", types: ["ci"] }] },
  });
  eq(
    JSON.stringify(ciOnly.entries.map((e) => e.dim.name).sort()),
    JSON.stringify(["correctness", "scope-drift", "security"]),
    "selectReviewDimensions: ci-only delta keeps generic security/correctness (#529), drops tests + decomposition",
  );
  eq(
    ciOnly.entries.find((e) => e.dim.name === "security")?.diff,
    deltaDiff,
    "selectReviewDimensions: ci-only security reads the DELTA diff (touched path)",
  );

  // A genuinely irrelevant delta (test-only) drops security + correctness (neither
  // touches `test`) — the actual saving — while tests + decomposition + scope-drift run.
  const testOnly = call({
    deltaFiles: ["x_test.py"],
    manifest: { classifications: [{ file: "x_test.py", types: ["test"] }] },
  });
  const testOnlyNames = testOnly.entries.map((e) => e.dim.name).sort();
  eq(
    JSON.stringify(testOnlyNames),
    JSON.stringify(["decomposition", "scope-drift", "tests"]),
    "selectReviewDimensions: test-only delta drops security/correctness (the saving)",
  );

  // AC#3 — prior-blocking carry-over: a dimension that blocked last cycle re-runs
  // even when the delta doesn't touch its types. CRUCIALLY it reads the FULL diff,
  // not the delta: the finding it must re-confirm may live OUTSIDE the fix delta, so
  // handing it only the delta would blind it (pre-PR review merge-safety finding).
  const prior = call({
    deltaFiles: ["x_test.py"],
    manifest: { classifications: [{ file: "x_test.py", types: ["test"] }] },
    priorBlocking: ["security"],
  });
  const priorNames = prior.entries.map((e) => e.dim.name);
  ok(priorNames.includes("security"), "selectReviewDimensions: a prior-blocking dimension re-runs regardless of delta types (AC#3)");
  eq(
    prior.entries.find((e) => e.dim.name === "security").diff,
    fullDiff,
    "selectReviewDimensions: a prior-blocking-ONLY dimension reads the FULL diff to re-confirm (not the delta)",
  );
  // A touched-AND-prior dimension also reads the full diff — re-confirmation wins.
  const both = call({
    deltaFiles: ["a.py"],
    manifest: { classifications: [{ file: "a.py", types: ["source"] }] },
    priorBlocking: ["security"],
  });
  eq(
    both.entries.find((e) => e.dim.name === "security").diff,
    fullDiff,
    "selectReviewDimensions: a dimension both touched AND prior-blocking reads the full diff (re-confirm wins)",
  );
  // A touched-ONLY dimension (relevant, not prior-blocking) reads the delta — the saving.
  eq(
    both.entries.find((e) => e.dim.name === "tests").diff,
    deltaDiff,
    "selectReviewDimensions: a touched-only dimension reads the delta diff (the saving)",
  );

  // includeSpecialist (#492 pre-PR review AC#3 gap): database/devops specialists are
  // gated separately from selectReviewDimensions, so they get their OWN
  // prior-blocking carry-over. A full cycle (narrowed=false) reduces to the plain
  // manifest.needs gate; a narrowed cycle ALSO re-runs a specialist that blocked
  // last cycle even when the fix touched no file of its type (manifest.needs false).
  const priorDb = new Set(["database"]);
  const noPrior = new Set();
  // Full cycle: manifest.needs is the sole gate — prior-blocking does NOT leak in.
  eq(includeSpecialist("database", true, noPrior, false), true, "includeSpecialist: full cycle runs a needed specialist");
  eq(includeSpecialist("database", false, priorDb, false), false, "includeSpecialist: full cycle does NOT carry over prior-blocking (byte-identical to before)");
  // Narrowed cycle: needs OR prior-blocking.
  eq(includeSpecialist("database", true, noPrior, true), true, "includeSpecialist: narrowed cycle runs a needed specialist");
  eq(includeSpecialist("database", false, priorDb, true), true, "includeSpecialist: narrowed cycle re-runs a prior-blocking specialist even when the delta needs it not (AC#3)");
  eq(includeSpecialist("database", false, noPrior, true), false, "includeSpecialist: narrowed cycle drops a specialist that neither is needed nor blocked");
  eq(includeSpecialist("devops", false, new Set(["devops"]), true), true, "includeSpecialist: the carry-over is keyed per specialist name (devops)");

  // diffForInclusion (#492 merge-safety fix): only a narrowed + touched + NOT-prior
  // inclusion reads the delta; every other combination reads the full diff so a
  // re-confirm (prior-blocking) can see a finding that may live outside the delta.
  eq(diffForInclusion(true, true, false, "FULL", "DELTA"), "DELTA", "diffForInclusion: narrowed + touched-only reads the delta (the saving)");
  eq(diffForInclusion(true, true, true, "FULL", "DELTA"), "FULL", "diffForInclusion: touched AND prior reads the full diff (re-confirm wins)");
  eq(diffForInclusion(true, false, true, "FULL", "DELTA"), "FULL", "diffForInclusion: prior-only reads the full diff (re-confirm outside the delta)");
  eq(diffForInclusion(false, true, false, "FULL", "DELTA"), "FULL", "diffForInclusion: a full cycle always reads the full diff");

  // The per-call `diff` argument (#492) is the mechanism that hands a delta-local
  // dimension `deltaDiff` instead of the module-level `scopeDiff`. Seed a distinct
  // scopeDiff via args, then call the prompt builders with an explicit third
  // argument and assert the explicit diff — not scopeDiff — is what gets spliced in.
  // A regression that stopped forwarding the diff through reviewerData/diffSection
  // would silently make every narrowed dimension read the full diff again.
  const { reusedReviewerPrompt: rp, newReviewerPrompt: np } = extractHelpers(
    SHIP,
    ["reusedReviewerPrompt", "newReviewerPrompt"],
    { diff: "SCOPE-DIFF-MARKER" },
  );
  const m = { files: ["a.py"], classifications: [{ file: "a.py", types: ["source"] }] };
  const reusedDelta = rp({ name: "security", mode: "security", category: "security" }, m, "DELTA-DIFF-MARKER");
  ok(reusedDelta.includes("DELTA-DIFF-MARKER"), "reusedReviewerPrompt: the explicit third diff arg is spliced in");
  ok(!reusedDelta.includes("SCOPE-DIFF-MARKER"), "reusedReviewerPrompt: the per-call diff wins over module scopeDiff");
  const newDelta = np({ name: "tests", category: "tests", instructions: "x" }, m, "DELTA-DIFF-MARKER");
  ok(newDelta.includes("DELTA-DIFF-MARKER"), "newReviewerPrompt: the explicit third diff arg is spliced in");
  ok(!newDelta.includes("SCOPE-DIFF-MARKER"), "newReviewerPrompt: the per-call diff wins over module scopeDiff");
  // Default (no third arg) still falls back to the module scopeDiff — the
  // full-cycle / non-narrowing path is unchanged.
  const reusedDefault = rp({ name: "security", mode: "security", category: "security" }, m);
  ok(reusedDefault.includes("SCOPE-DIFF-MARKER"), "reusedReviewerPrompt: default diff falls back to module scopeDiff");

  // manifestPrompt narrows the MANIFEST step itself on a re-review cycle: it feeds
  // deltaFiles/deltaDiff into the two-arg scopeHeader so manifest.needs (specialist
  // gating) reflects the fix delta, not the whole PR. Seed a narrowed vs a full
  // extraction and assert each sees the right file list.
  const { manifestPrompt: mpNarrowed } = extractHelpers(
    SHIP,
    ["manifestPrompt"],
    {
      cycle: 2,
      phase: "pr-cycle",
      files: ["full-a.js", "full-b.js"],
      diff: "FULL-DIFF-MARKER",
      deltaFiles: ["delta-only.js"],
      deltaDiff: "DELTA-DIFF-MARKER",
    },
  );
  const narrowedPrompt = mpNarrowed();
  ok(narrowedPrompt.includes("delta-only.js"), "manifestPrompt: narrowed cycle builds the manifest over deltaFiles");
  ok(!narrowedPrompt.includes("full-a.js"), "manifestPrompt: narrowed cycle does NOT use the full PR file list");
  const { manifestPrompt: mpFull } = extractHelpers(
    SHIP,
    ["manifestPrompt"],
    { cycle: 1, phase: "pre-pr", files: ["full-a.js"], diff: "FULL-DIFF-MARKER", deltaFiles: ["delta-only.js"], deltaDiff: "DELTA-DIFF-MARKER" },
  );
  const fullPrompt = mpFull();
  ok(fullPrompt.includes("full-a.js"), "manifestPrompt: cycle 1 builds the manifest over the full file list");
  ok(!fullPrompt.includes("delta-only.js"), "manifestPrompt: cycle 1 ignores the delta (narrowing off)");
}
}
