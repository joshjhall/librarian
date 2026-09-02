#!/usr/bin/env node
// Copy the shared prelude into every consuming workflow.js harness (#586).
//
// WHY A COPY-OUT AND NOT AN IMPORT. The Workflow engine parses a workflow.js as
// a SCRIPT, so no import spelling works — #712 probed all three. A harness
// therefore cannot reach a shared module at runtime, and the only mechanism that
// keeps N copies honest is to generate them from one source and gate the result.
// The day the engine supports modules (#90), this generator is deleted and each
// region becomes one import line, with no re-analysis of what is shared.
//
// WHY DELIVERY FORM DIFFERS BY HARNESS (#811 — recorded in dev-core's
// workflow-authoring skill under contract id `prelude-generator-coexistence`):
//
//   ENROLLED in generate-workflow-js.mjs (ship-issue, codebase-audit)
//     -> a FRAGMENT file, workflow.src/NN-prelude.js, listed in manifest.txt.
//        NEVER a banner region inside the artifact: that generator rewrites the
//        artifact wholesale from its fragments, so a region written there is
//        overwritten on its next run, and stale (a failing
//        tests/lint-workflow-js-generated.sh) in the meantime. Two tools would
//        be fighting over the same bytes.
//   NOT ENROLLED (code-reviewer, orchestrate, rebase-agent, ci-fixer)
//     -> a banner-delimited REGION rewritten in place inside workflow.js.
//
// The two gates then own DISJOINT byte ranges — this one owns
// source -> fragment/region, that one owns fragments -> artifact — so they
// compose in series and can never disagree about a byte.
//
// WHY SECTIONS. A consumer receives only the section(s) it uses, so ci-fixer
// (whose sole shared symbol is BUDGET_FLOOR) is not handed prompt helpers it
// never calls. Section boundaries are the `// >>> prelude:<name>` /
// `// <<< prelude:<name>` markers in plugins/lib/prelude.js.
//
// IDEMPOTENCY is by construction: the emitted text is a pure function of the
// source sections, and writing is skipped when the bytes already match. Running
// twice is a no-op.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// bin/ -> repo root.
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const SOURCE_REL = "plugins/lib/prelude.js";

// Which sections each consumer receives, and how it receives them.
//
// `mode: "fragment"` targets a path under the harness's workflow.src/ and is
// reserved for harnesses enrolled in generate-workflow-js.mjs; `mode: "region"`
// rewrites a banner-delimited region inside the harness file itself. Mixing
// these up is the #811 failure, so the mode is explicit per consumer rather
// than inferred.
const CONSUMERS = [
  {
    harness: "plugins/workflow/skills/ship-issue/workflow.js",
    mode: "fragment",
    target: "plugins/workflow/skills/ship-issue/workflow.src/15-prelude.js",
    sections: ["budget-floor", "review-scaffolding"],
  },
  {
    harness: "plugins/review-audit/skills/codebase-audit/workflow.js",
    mode: "fragment",
    target: "plugins/review-audit/skills/codebase-audit/workflow.src/15-prelude.js",
    sections: ["budget-floor", "review-scaffolding"],
  },
  {
    harness: "plugins/dev-core/agents/code-reviewer/workflow.js",
    mode: "region",
    target: "plugins/dev-core/agents/code-reviewer/workflow.js",
    sections: ["budget-floor", "review-scaffolding"],
  },
  {
    harness: "plugins/workflow/skills/orchestrate/workflow.js",
    mode: "region",
    target: "plugins/workflow/skills/orchestrate/workflow.js",
    sections: ["budget-floor", "ref-guard"],
  },
  {
    harness: "plugins/workflow/agents/rebase-agent/workflow.js",
    mode: "region",
    target: "plugins/workflow/agents/rebase-agent/workflow.js",
    sections: ["budget-floor", "ref-guard"],
  },
  {
    harness: "plugins/workflow/agents/ci-fixer/workflow.js",
    mode: "region",
    target: "plugins/workflow/agents/ci-fixer/workflow.js",
    sections: ["budget-floor"],
  },
];

const BANNER_START = "// ==== GENERATED FROM plugins/lib/prelude.js — DO NOT EDIT ====";
const BANNER_END = "// ==== END GENERATED ====";

// Parse the source into named sections. Fails loudly on a malformed marker pair
// rather than silently emitting less than the caller asked for — a section that
// quietly resolved to empty would delete working code from every consumer.
export function readSections(sourceText) {
  const sections = new Map();
  const lines = sourceText.split("\n");
  let current = null;
  let buf = [];

  for (const line of lines) {
    const open = line.match(/^\/\/ >>> prelude:([a-z0-9-]+)$/);
    const close = line.match(/^\/\/ <<< prelude:([a-z0-9-]+)$/);

    if (open) {
      if (current) throw new Error(`nested section marker: ${open[1]} inside ${current}`);
      current = open[1];
      buf = [];
      continue;
    }
    if (close) {
      if (!current) throw new Error(`close marker with no open section: ${close[1]}`);
      if (close[1] !== current) {
        throw new Error(`mismatched section markers: opened ${current}, closed ${close[1]}`);
      }
      if (sections.has(current)) throw new Error(`duplicate section: ${current}`);
      sections.set(current, buf.join("\n").replace(/^\n+|\n+$/g, ""));
      current = null;
      continue;
    }
    if (current) buf.push(line);
  }

  if (current) throw new Error(`unterminated section: ${current}`);
  if (sections.size === 0) throw new Error("no sections found in prelude source");
  return sections;
}

// The exact text a consumer receives, banner included. Pure function of the
// source sections and the requested names — this is what makes idempotency and
// the sync check the same computation.
export function renderRegion(sections, names) {
  const missing = names.filter((n) => !sections.has(n));
  if (missing.length > 0) {
    throw new Error(
      `unknown prelude section(s): ${missing.join(", ")}\n` +
        `  available: ${[...sections.keys()].join(", ")}`,
    );
  }
  const body = names.map((n) => sections.get(n)).join("\n\n");
  return `${BANNER_START}\n${body}\n${BANNER_END}\n`;
}

// A fragment file is the region text plus a short provenance header. The header
// is OUTSIDE the banner so the sync gate compares only generated bytes.
function renderFragment(sections, names) {
  return (
    `// @generated from ${SOURCE_REL} by bin/generate-prelude.mjs — DO NOT EDIT.\n` +
    `// Edit the source, then run: just gen-prelude\n` +
    `//\n` +
    `// This harness is ENROLLED in bin/generate-workflow-js.mjs, so its prelude\n` +
    `// arrives as a FRAGMENT rather than a banner region inside the artifact\n` +
    `// (#811). A region written into the artifact would be overwritten by the\n` +
    `// next \`just gen-workflow-js\`, and fail lint-workflow-js-generated.sh as\n` +
    `// stale until then.\n` +
    `\n` +
    renderRegion(sections, names)
  );
}

// Replace the banner-delimited region in an existing harness file.
//
// Requires the region to already exist: this generator does not guess where a
// prelude belongs. Placement is a human decision (it interacts with
// module-load-order constraints the manifests document), so a missing region is
// an error telling the author to add the markers, never a silent append.
export function spliceRegion(fileText, regionText, relPath) {
  const startIdx = fileText.indexOf(BANNER_START);
  const endIdx = fileText.indexOf(BANNER_END);

  if (startIdx === -1 || endIdx === -1) {
    throw new Error(
      `no generated region in ${relPath}\n` +
        `  add these markers where the prelude belongs, then re-run:\n` +
        `    ${BANNER_START}\n    ${BANNER_END}`,
    );
  }
  if (endIdx < startIdx) {
    throw new Error(`malformed region in ${relPath}: end marker precedes start marker`);
  }
  if (fileText.indexOf(BANNER_START, startIdx + 1) !== -1) {
    throw new Error(`multiple generated regions in ${relPath}: expected exactly one`);
  }

  const before = fileText.slice(0, startIdx);
  const after = fileText.slice(endIdx + BANNER_END.length);
  // regionText already ends in a newline after its end marker; drop that so the
  // trailing text is reattached exactly as it was found.
  return before + regionText.replace(/\n$/, "") + after;
}

// The bytes `target` SHOULD hold, for one consumer.
export function renderTarget(consumer, sections) {
  if (consumer.mode === "fragment") {
    return renderFragment(sections, consumer.sections);
  }
  const current = readFileSync(join(repoRoot, consumer.target), "utf8");
  return spliceRegion(current, renderRegion(sections, consumer.sections), consumer.target);
}

export function loadSections() {
  return readSections(readFileSync(join(repoRoot, SOURCE_REL), "utf8"));
}

export { CONSUMERS, SOURCE_REL, BANNER_START, BANNER_END };

function main(argv) {
  const check = argv.includes("--check");
  const rest = argv.filter((a) => a !== "--check");

  const unknownFlags = rest.filter((a) => a.startsWith("-"));
  if (unknownFlags.length > 0) {
    process.stderr.write(`generate-prelude: unknown flag(s): ${unknownFlags.join(", ")}\n`);
    return 2;
  }

  let targets;
  if (rest.length > 0) {
    targets = [];
    for (const arg of rest) {
      const matches = CONSUMERS.filter(
        (c) => c.harness === arg || dirname(c.harness).endsWith(`/${arg}`),
      );
      if (matches.length !== 1) {
        process.stderr.write(
          `generate-prelude: not a prelude consumer: ${arg}\n  consumers:\n    ` +
            `${CONSUMERS.map((c) => c.harness).join("\n    ")}\n`,
        );
        return 2;
      }
      targets.push(matches[0]);
    }
  } else {
    targets = CONSUMERS;
  }

  let sections;
  try {
    sections = loadSections();
  } catch (err) {
    process.stderr.write(`generate-prelude: ${err.message}\n`);
    return 2;
  }

  let failed = 0;
  for (const consumer of targets) {
    const targetPath = join(repoRoot, consumer.target);
    let rendered;
    try {
      rendered = renderTarget(consumer, sections);
    } catch (err) {
      process.stderr.write(`generate-prelude: ${err.message}\n`);
      failed += 1;
      continue;
    }

    let current = null;
    try {
      current = readFileSync(targetPath, "utf8");
    } catch {
      current = null;
    }

    if (check) {
      if (current === null) {
        process.stderr.write(`generate-prelude: missing generated file: ${consumer.target}\n`);
        failed += 1;
        continue;
      }
      if (current !== rendered) {
        process.stderr.write(
          `generate-prelude: STALE prelude copy: ${consumer.target}\n` +
            `  it does not match ${SOURCE_REL}.\n` +
            `  Edit the SOURCE, then regenerate: just gen-prelude\n`,
        );
        failed += 1;
        continue;
      }
      process.stdout.write(`ok  ${consumer.target}\n`);
      continue;
    }

    if (current === rendered) {
      process.stdout.write(`unchanged  ${consumer.target}\n`);
      continue;
    }
    writeFileSync(targetPath, rendered);
    process.stdout.write(`wrote  ${consumer.target}\n`);
  }

  return failed > 0 ? 1 : 0;
}

// Only run main when invoked directly, so the exports above stay importable by
// tests without triggering a write.
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}
