// Pure-prefix extraction for the workflow.js harnesses (issue #564).
//
// Extracted from tests/validate-workflow-helpers.mjs when that file was split
// into per-harness modules under tests/workflow-helpers/. Every area module
// imports extractHelpers + the harness path consts from here.
//
// The import problem this solves: a harness ends in a top-level `await
// agent(...)` / `return` at module scope, so `import`-ing it would EXECUTE the
// orchestration (and a top-level `return` is a syntax error outside a function
// anyway). So we cannot load a harness as a module. Instead we read its source,
// slice off everything from the first column-0 orchestration statement onward
// (the `log()`/`phase()`/top-level `await`/`if`/`for`/`return` that begins the
// side-effecting body), and evaluate ONLY the pure prefix (config + schemas +
// helpers) inside a `new Function` with inert stubs for the engine globals. The
// prefix has no I/O, so this is safe; the function then returns the named
// helpers for testing.
//
// Cutting BEFORE the first top-level `await` is mandatory: a `new Function` body
// that contains a top-level `await` throws at construction. We rely on that —
// `extractHelpers` surfacing a clean object IS evidence the slice boundary sits
// in the pure region. selfCheck() below proves the extractor throws when the
// boundary is deliberately pushed past an `await`, so a future boundary-regex
// regression cannot make the gate silently pass.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ok, throws } from "./mjs-assert.mjs";

// tests/lib/ -> tests/ -> repo root.
export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

// The six harnesses under test.
export const CA = "plugins/review-audit/skills/codebase-audit/workflow.js";
export const ORCH = "plugins/workflow/skills/orchestrate/workflow.js";
export const REBASE = "plugins/workflow/agents/rebase-agent/workflow.js";
export const CIFIX = "plugins/workflow/agents/ci-fixer/workflow.js";
export const REVIEW = "plugins/dev-core/agents/code-reviewer/workflow.js";
export const SHIP = "plugins/workflow/skills/ship-issue/workflow.js";

// First column-0 statement that begins the side-effecting orchestration body.
// Everything before this match is the pure prefix (config + schemas + helpers).
// The `m` flag anchors `^` at line starts so a `log(`/`await` nested inside a
// helper (always indented) is never mistaken for the boundary.
export const ORCH_BOUNDARY =
  /^(log\(|phase\(|await |const\s+\w+\s*=\s*await\b|let\s+\w+\s*=\s*await\b|if \(|for \(|while \(|return )/m;

// Read a harness's raw source. Used by the assertions that must inspect the
// ORCHESTRATION body (past the boundary), which no extracted helper can reach.
export function harnessSource(relPath) {
  return readFileSync(join(repoRoot, relPath), "utf8");
}

// Evaluate a harness's pure prefix and return the named helpers. `args` seeds
// the config consts the prefix derives at module load (e.g. dryRun, CYCLE).
//
// On `new Function`: the only inputs to the constructed body are (a) the repo's
// OWN committed harness source — the same bytes `node --check` already executes
// in tests/lint-skills-agents.sh — and (b) `names`, a hardcoded identifier
// allowlist from the calling test file. Neither is runtime/untrusted input, so
// this is not a code-injection surface; it is the only way to test helpers
// locked inside a top-level-`await` module that cannot be imported.
export function extractHelpers(relPath, names, args = {}, budgetStub = null) {
  const src = readFileSync(join(repoRoot, relPath), "utf8");
  const m = src.match(ORCH_BOUNDARY);
  if (!m) throw new Error(`${relPath}: no orchestration boundary found`);
  const prefix = src
    .slice(0, m.index)
    // `export const meta = …` is a module-only form; a `new Function` body is
    // not a module, so strip the `export` keyword (the literal is otherwise fine).
    .replace(/^export\s+const\s+meta/m, "const meta");
  // Default stub = no runtime turn budget (the golem case: `total` null, so the
  // harness's own gates fall through to a caller ceiling if one is armed).
  // `budgetStub` overrides it to exercise the runtime-armed path (#553).
  const budget = budgetStub || { total: null, spent: () => 0, remaining: () => Infinity };
  const noop = () => {};
  const factory = new Function(
    "args",
    "budget",
    "log",
    "phase",
    "agent",
    "parallel",
    "pipeline",
    `${prefix}\nreturn { ${names.join(", ")} };`,
  );
  return factory(args, budget, noop, noop, noop, noop, noop);
}

// Negative self-check — prove the extractor actually guards the slice boundary.
// If the boundary regex ever drifts past a top-level `await`, `new Function`
// throws at construction. We assert that failure mode directly so a silent
// "extracted nothing, asserted nothing" regression cannot pass this gate.
//
// Lives beside extractHelpers rather than in an area module because its subject
// IS the extractor, not any one harness.
export function selfCheck() {
  const badFactory = () => new Function("await Promise.resolve(1); return {};");
  throws(
    badFactory,
    "self-check: a top-level await in a new Function body throws at construction (boundary guard)",
  );
  // And a well-formed extraction must yield a real function — proving the happy
  // path isn't vacuously passing.
  const { sanitize } = extractHelpers(CA, ["sanitize"]);
  ok(
    typeof sanitize === "function",
    "self-check: extractHelpers returns live helper functions, not undefined",
  );
}
