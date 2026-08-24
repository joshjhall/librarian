// delegation — investigation-delegation guidance and its SCOPE_DISCIPLINE
// boundary (issue #785).
//
// Cross-cutting by nature: the guidance is ONE skill in dev-core referenced from
// two consumer phases in two other plugins, and its correctness claim spans all
// three plus ship-issue's reviewer prompts. So it lives in its own area module
// rather than being duplicated into the per-harness ones — the same reasoning
// that put the model-tier assertions in model-tier.mjs (#564 split shape).
//
// It is also why this is a NEW file rather than more lines in ship-issue.mjs:
// the plan-lens flagged that module at 1,374 production LOC against an 800
// budget, so growing it to hold a cross-harness area would have been the wrong
// seam twice over.
//
// WHAT THIS GATE PROTECTS. #785 routes read-only investigation to subagents; the
// measured hazard is that the SAME prose leaks into the review harness's
// reviewer prompts, where it would undo #553/#557's bounding (per-reviewer Bash
// calls 31.5 -> 2.2) and re-introduce unbounded exploration at a ~24.5k spawn
// premium each. #785's AC4 asks for confirmation that reviewer behavior did not
// regress; an unchanged file is not evidence, so the leak check below is the
// assertion that makes it one.
//
// Assertions are collect-all (they record, never throw), so a failure here does
// not mask any sibling area — see tests/lib/mjs-assert.mjs.

import { readFileSync } from "node:fs";
import { join } from "node:path";

import { ok } from "../lib/mjs-assert.mjs";
import { harnessSource, repoRoot, SHIP } from "../lib/extract-helpers.mjs";

const SKILL_DIR = "plugins/dev-core/skills/delegating-investigation";
const SKILL = `${SKILL_DIR}/SKILL.md`;
const META = `${SKILL_DIR}/metadata.yml`;

// The two consumer phases wired in #785. Named as data so a third consumer is a
// one-line addition and so a failure message names which phase lost the ref.
const CONSUMERS = [
  ["next-issue planning", "plugins/workflow/skills/next-issue/phase2-plan.md"],
  [
    "codebase-audit survey",
    "plugins/review-audit/skills/codebase-audit/orchestration-protocol.md",
  ],
];

// The measured break-even. Both figures are cited from the repo's own
// measurements (#787 n=301 spawns; #785's 24h classification) rather than
// re-derived, so the test pins the CITATION, not an arithmetic result.
const SPAWN_PREFIX = "24,568";

function readIfPresent(relPath) {
  try {
    return readFileSync(join(repoRoot, relPath), "utf8");
  } catch {
    return null;
  }
}

export function run() {
  // ===========================================================================
  // The skill exists and is packaged correctly
  // ===========================================================================
  // lint-skills-agents.sh enforces the directory shape generally; these two
  // assertions are here so that a MISSING skill fails as "the delegation skill
  // is gone" rather than as a wall of confusing content-assertion failures
  // below, all of which would read as prose regressions.
  const skill = readIfPresent(SKILL);
  const meta = readIfPresent(META);
  ok(skill !== null, `delegating-investigation: ${SKILL} exists`);
  ok(meta !== null, `delegating-investigation: ${META} exists (lint-skills-agents.sh requires it)`);
  ok(
    (meta || "").includes("name: delegating-investigation"),
    "delegating-investigation: metadata.yml declares the matching skill name",
  );

  // ===========================================================================
  // The break-even is STATED, with both of its terms (#785 AC2)
  // ===========================================================================
  // AC2 asks for a break-even "computed from measured data and stated in the
  // guidance". A skill that says "delegate when it's worth it" satisfies the
  // prose and none of the intent, so each term is pinned separately:
  //
  //   cost to delegate  = the median spawn prefix (a fixed, measured number)
  //   cost not to       = result volume TIMES turns resident (the multiplier)
  //
  // The multiplier is the term most likely to be dropped by a well-meaning
  // trim, and it is the one that usually decides the comparison — a 40k result
  // is not a 40k cost when it sits in context for another 30 turns.
  if (skill) {
    ok(
      skill.includes(SPAWN_PREFIX),
      `delegating-investigation: states the measured spawn prefix (${SPAWN_PREFIX}, #787)`,
    );
    ok(
      /re-read debt/i.test(skill),
      "delegating-investigation: names re-read debt as the other side of the break-even",
    );
    ok(
      /turns_resident|turns it stays resident|turns resident/i.test(skill),
      "delegating-investigation: the break-even multiplies result volume by turns resident",
    );

    // =========================================================================
    // The exclusion is explicit (#785 AC3)
    // =========================================================================
    // AC3 exists because over-delegation is the failure mode that makes agents
    // SLOWER — a one-line lookup routed through a subagent pays the full prefix
    // to save a few hundred tokens. Guidance that only says when to delegate
    // reads as "delegate", so the negative case must be present in its own
    // right.
    ok(
      /Do NOT delegate/i.test(skill),
      "delegating-investigation: carries an explicit do-not-delegate section (AC3)",
    );
    ok(
      /known file|already know|targeted read/i.test(skill),
      "delegating-investigation: excludes targeted single-file reads from delegation (AC3)",
    );

    // =========================================================================
    // The dispatch tier is NAMED (#785's title: "to sonnet subagents")
    // =========================================================================
    // The break-even alone is not actionable: an agent that applies it correctly
    // and then spawns an OPUS subagent forfeits the repricing half of the saving
    // entirely (opus-5 is 1.93x sonnet-5 per token on this fleet) while still
    // paying the 24.5k prefix. The guidance must say which tier, and how to set
    // it, or "delegate to sonnet subagents" is left to inference.
    ok(
      /sonnet/i.test(skill),
      "delegating-investigation: names the sonnet tier for delegated investigation",
    );
    ok(
      /agentType|model: 'sonnet'|Explore/.test(skill),
      "delegating-investigation: names a concrete dispatch mechanism, not just a tier",
    );

    // =========================================================================
    // Conclusions, not transcripts (#785 AC5)
    // =========================================================================
    // This is the half of the saving that repricing does not deliver: if the
    // subagent returns what it read, the parent context absorbs the exploration
    // anyway and the delegation bought only a spawn prefix.
    ok(
      /not a transcript|never a transcript|not transcripts/i.test(skill),
      "delegating-investigation: subagents return conclusions, not transcripts (AC5)",
    );
    ok(
      /file:line/i.test(skill),
      "delegating-investigation: conclusions carry file:line anchors",
    );

    // =========================================================================
    // The skill names its own boundary against SCOPE_DISCIPLINE
    // =========================================================================
    // #785's body warns not to weaken SCOPE_DISCIPLINE in the name of
    // delegation. The durable protection is not that today's author knew that —
    // it is that the skill SAYS so, so a future editor reconciling two
    // apparently-contradictory rules finds the reason they differ instead of
    // harmonizing them.
    ok(
      skill.includes("SCOPE_DISCIPLINE"),
      "delegating-investigation: names SCOPE_DISCIPLINE and the boundary against it",
    );
  }

  // ===========================================================================
  // Both consumer phases reference the skill, namespaced
  // ===========================================================================
  // AC1 routes investigation-heavy phases by default. Guidance that ships
  // without a reference at the decision point may simply never load at the
  // moment the decision is made, which is the difference between a rule and a
  // document. The ref must be NAMESPACED (/dev-core:...) per CLAUDE.md — a bare
  // /delegating-investigation does not resolve in a marketplace install, and
  // lint-command-refs.sh enforces the form repo-wide.
  for (const [label, path] of CONSUMERS) {
    const src = readIfPresent(path);
    ok(src !== null, `${label}: ${path} exists`);
    ok(
      (src || "").includes("/dev-core:delegating-investigation"),
      `${label}: references /dev-core:delegating-investigation (namespaced, AC1)`,
    );
    ok(
      (src || "").includes(SPAWN_PREFIX),
      `${label}: carries the break-even figure at the decision point (AC2)`,
    );
  }

  // ===========================================================================
  // SCOPE_DISCIPLINE did not regress, and the guidance did not leak into it
  // ===========================================================================
  // #785 AC4: "SCOPE_DISCIPLINE is unchanged; a test or review note confirms
  // reviewer behavior did not regress."
  //
  // Two DISTINCT claims, and the second is the one with teeth:
  //
  //   (a) the bounding clauses are still there  — catches a deletion
  //   (b) delegation prose did NOT leak in      — catches an ADDITION
  //
  // (a) alone would pass a workflow.js that kept every original sentence and
  // appended "route fan-out reading to a subagent" underneath, which is exactly
  // the plausible regression: a future editor applying #785 repo-wide, seeing
  // reviewer prompts full of investigation, and "finishing the job". That
  // reviewer would then dispatch subagents from inside the fan-out — unbounded
  // exploration at a 24.5k premium per spawn, the precise cost #553/#557 removed.
  {
    const src = harnessSource(SHIP);

    // (a) The bounding clauses survive. Kept deliberately narrow: this area owns
    // the #785 non-regression claim, while ship-issue.mjs owns SCOPE_DISCIPLINE's
    // full content contract. Duplicating that contract here would create two
    // tables over the same text that must agree — the duplication CLAUDE.md's
    // #663 rule exists to prevent.
    ok(
      /const SCOPE_DISCIPLINE\s*=/.test(src),
      "SCOPE_DISCIPLINE: still defined after #785",
    );
    // End the slice at the const's OWN terminator — the next top-level `const`
    // declaration — not at whatever comment happens to follow it today.
    //
    // The tempting anchor is the neighbouring "// `sanitize`" comment, and it is
    // a trap: re-wording that unrelated comment makes indexOf return -1, which
    // slices to end-of-file. The two content assertions below would still PASS
    // (their phrases are in the const either way), so the window would silently
    // widen to whole-file matching with nothing failing to announce it — the
    // gate would keep reporting green while no longer checking what it claims.
    // So a lost boundary is asserted, never absorbed.
    const sdStart = src.indexOf("const SCOPE_DISCIPLINE =");
    ok(sdStart !== -1, "SCOPE_DISCIPLINE: start boundary located");
    const sdRest = sdStart === -1 ? "" : src.slice(sdStart);
    const sdEnd = sdRest.search(/\n(?:\/\/[^\n]*\n)*const\s/);
    ok(
      sdStart === -1 || sdEnd !== -1,
      "SCOPE_DISCIPLINE: end boundary located (slice is a real window, not the whole file)",
    );
    const sd = sdEnd === -1 ? sdRest : sdRest.slice(0, sdEnd);

    // SCOPE_DISCIPLINE is built by concatenating adjacent string literals, so a
    // sentence can straddle a `' + '` join. Collapsing whitespace alone is NOT
    // enough — it leaves the quote-plus-quote artifact mid-phrase, and a matcher
    // that happens to sit inside one literal today silently stops matching when
    // someone re-wraps the prose. Splice the joins out first, THEN collapse.
    const sdText = sd.replace(/'\s*\+\s*'/g, "").replace(/\s+/g, " ");
    ok(
      /Budget yourself roughly 10 tool calls/i.test(sdText),
      "SCOPE_DISCIPLINE: reviewers still get an explicit tool-call budget (#785 AC4)",
    );
    ok(
      /Do NOT survey the repo/i.test(sdText),
      "SCOPE_DISCIPLINE: reviewers are still told not to survey the repo (#785 AC4)",
    );

    // (b) The leak check, scanned over PROMPT TEXT ONLY — comments stripped.
    //
    // Scope is deliberately wider than SCOPE_DISCIPLINE (the hazard is guidance
    // reaching a reviewer through ANY prompt builder, so a check pinned to one
    // const would miss it arriving via a sibling), but it must not be the raw
    // file: a future editor documenting this very boundary in a comment —
    // "// see /dev-core:delegating-investigation for why this must not change",
    // exactly the self-documenting comment the new SKILL.md argues for — would
    // trip a raw-source check while no reviewer prompt had changed. A gate that
    // fires on correct, desirable edits gets deleted, and then catches nothing.
    //
    // Stripping comments keeps the assertion aimed at what actually reaches an
    // agent: string literals. Prose in a comment is inert; prose in a prompt is
    // the regression.
    const promptText = src
      .replace(/\/\*[\s\S]*?\*\//g, "") // block comments
      .replace(/^[ \t]*\/\/[^\n]*$/gm, "") // whole-line // comments
      .replace(/[ \t]+\/\/[^\n'"]*$/gm, ""); // trailing // comments (quote-free only,
    // so a `//` inside a URL string literal is never mistaken for a comment)
    ok(
      !promptText.includes("/dev-core:delegating-investigation"),
      "SCOPE_DISCIPLINE: delegation skill ref has NOT leaked into reviewer prompts (#785 AC4)",
    );
    ok(
      !promptText.includes(SPAWN_PREFIX),
      `SCOPE_DISCIPLINE: the ${SPAWN_PREFIX} break-even has NOT leaked into reviewer prompts (#785 AC4)`,
    );
  }
}
