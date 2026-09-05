---
description: Guidelines for writing Claude Code workflow.js harnesses — the Workflow-tool scripts that fan out subagents under a shared budget. Use when creating or reviewing a workflow.js harness or its agent contract.
---

# Workflow Authoring

Guidance for `workflow.js` harnesses — the deterministic scripts run by the
Workflow tool that orchestrate subagents (fan-out, shared token budget, per-step
resume) on behalf of a skill or agent. The harness owns control flow; the agent
it drives owns one mode per invocation. Companion to `agent-authoring` (for the
agent the harness drives) and `adversarial-review` (for the self-review pass).

## Harness Anatomy

- **`export const meta`** must be a PURE LITERAL — no variables, calls, or
  interpolation. Required: `name`, `description`. List one `phases` entry per
  `phase()` call, with matching titles. Common trap: splitting a long
  `description` across lines with `'...' + '...'` concatenation — that `+` is a
  BinaryExpression, not a literal, and the tool rejects the whole script with
  "meta must be a pure literal". Keep each meta string on ONE line (a single
  long quoted literal is fine). Enforced by
  `tests/lint-skills-agents.sh`.
- **Discriminated agent modes**: drive one `agentType` in modes named in the
  prompt (`manifest`, `reviewer:<name>`, `rescore`, `merge`, …). The agent does
  one mode per call; the harness sequences them. `agentType` MUST be the
  **namespaced `<plugin>:<name>`** form (`dev-core:code-reviewer`,
  `review-audit:checker`, …) — the Workflow tool's `agent()` resolver keys
  agents only by that form. This is the OPPOSITE of the `Agent` tool's
  `subagent_type`, which takes the **bare** name; a bare `agentType` passes a
  basename check but throws at runtime (issue #126).
- **Per-stage model / effort escalation**: `agent()` accepts an optional
  `model` (and `effort`) opt that overrides the sub-agent's own frontmatter tier
  for that one call — same tokens as frontmatter (`fable`, `opus`, `sonnet`,
  `haiku`, a full model ID, or `inherit`). Reserve it for the **adversarial
  verify stages** — the "FRESH judge panel, you did NOT produce these findings"
  re-scorers — where a wrong verdict drops a real finding or ships a false
  positive: those pin `model: 'opus'` while the base scan/review stages stay on
  the agent's default tier. Example (the `rescore` stage in
  `code-reviewer/workflow.js`):

  ```js
  const rescored = await agent(rescorePrompt(rawFindings), {
    label: 'rescore', phase: 'Rescore',
    agentType: 'dev-core:code-reviewer',
    model: 'opus', // last gate before a finding surfaces — quality compounds
    schema: RESCORE_SCHEMA,
  })
  ```

  `opus` is the ceiling for these gates, not `fable`. What makes a judge stage
  accurate is the fresh context — it did not produce the findings it is scoring
  — plus the adversarial framing; the tier is the smaller lever. `fable` costs
  roughly 2x opus per token and did not buy a matching gain at these gates, so
  the three harness judge/verify passes moved down to `opus` (#526). Reach for
  `fable` only with a measured result that justifies it.
- **Typed schemas**: every `agent()` that returns data uses a JSON-Schema with
  `additionalProperties: false` and an explicit `required` list. Validation
  happens at the tool layer, so the model retries on mismatch.
- **`pipeline()` by default, `parallel()` only at a true barrier.** Use
  `parallel()` (a barrier) only when a later stage genuinely needs ALL prior
  results at once (dedup across the full set, early-exit on zero). Otherwise
  `pipeline()` — no wasted wall-clock.
- **Never call `workflow()`** — the one nesting level is reserved. A harness may
  itself run inside another (e.g. orchestrate → rebase-agent), so nesting throws.

## File Shape and Size

- **Never split a harness into sibling modules.** The engine parses a
  `workflow.js` as a *script*, so `import` resolves only to the dynamic-call form
  and that form is disabled — a split fails at parse, before any gate runs
  (probed live: #807, #90, #91). Two legitimate shapes exist instead, and which
  one applies depends on whether the harness is **enrolled in the generator**:
  - **Enrolled** (`bin/generate-workflow-js.mjs`'s list — currently `ship-issue`
    and `codebase-audit`): edit the ordered fragments in `workflow.src/` and run
    `just gen-workflow-js`. Concatenation needs no module system, so it sidesteps
    the ban entirely (#806). Never edit the generated artifact —
    `tests/lint-workflow-js-generated.sh` fails the tree as stale.
  - **Not enrolled** (`orchestrate`, `code-reviewer`, and the two agent
    harnesses): use the in-file shape — side-effecting body in a named
    `async function run…()`, banner rules, and a **column-0** dispatch call at
    the foot. `orchestrate/workflow.js` is the reference.
- **The dispatch call must stay at column 0.** `tests/lib/extract-helpers.mjs`'s
  `ORCH_BOUNDARY` is a column-0-anchored regex that slices each harness into its
  pure prefix (evaluated via `new Function`) and its orchestration body; indenting
  the call erases the boundary. Two layers cover it, and both are needed: the
  extractor throws `no orchestration boundary found` on an *indented* tail, and
  `code-reviewer`'s test area pins the tail literally
  (`/^return runReview\(\)$/m`). The throw alone is not enough — a restructure
  leaving some *other* column-0 statement still extracts cleanly while silently
  moving the prefix boundary, which only the literal pin catches. A repo-wide
  lint gate was evaluated in #718 and declined as redundant once both exist.
- **Build the result object in a pure helper BEFORE the boundary.** Everything
  past `ORCH_BOUNDARY` is unreachable by `extractHelpers`, and that is most of
  several harnesses — measured 2026-09-05: `ship-issue` 440 lines, `codebase-audit`
  404, `rebase-agent` 115, `ci-fixer` 110 (`orchestrate` and `code-reviewer` are
  1-4, because their bodies live in a named function). The terminal
  `return { … }` sits in that region, so every field it *derives* — a tally, a
  spread, a computed `clean` — has no regression coverage. Not hypothetical: on
  PR #634 an all-zero-distribution mutation to `ship-issue`'s return left the
  entire suite green (#636). Take inputs and do the derivations inside the helper
  (`buildResult`, `finalResult`) so the residue past the boundary is one call
  whose arguments a reader can eyeball; lifting only the object *literal* moves
  the untested expressions to the call site and buys nothing. Have every return
  path delegate to it — two hand-written literals agree only by inspection.
- **Cover a boundary-adjacent call site with BOTH layers.** The helper's behavior
  is unit-tested through `extractHelpers`; the one-line call is pinned literally
  against `harnessSource(...)`. Neither alone is enough — re-inlining the literal
  leaves every behavioral assertion passing against a helper nothing calls. Same
  pairing as the dispatch-tail rule above. Scope an *absence* check to the slice
  past the boundary (`src.slice(src.search(ORCH_BOUNDARY))`): the expression you
  are asserting is gone still exists in the prefix, so a whole-file check fails
  against the correct fix. Assert the slice is non-vacuous too, or a drifted
  boundary makes all of them pass trivially.
- **A test that counts N literal emission sites will fight this extraction.**
  Structural assertions written as "this field appears on both return paths"
  encode the duplication, so consolidating to one constructor fails them. Re-key
  them to the new structure — one emission, plus each call site threading its
  input — rather than relaxing the count; the property they guard is still real
  (#553/#616 were both re-keyed this way in #636, not deleted).
- **A raw-source assertion over an orchestration body must tolerate indentation.**
  Anchoring an *absence* check at `^` inside a wrapped body means it can never
  match, so it stays green whether or not the thing it guards survives. Write
  `/^[ \t]*const x = await agent\(/m`. Both #646 checks were re-anchored in #718
  for exactly this reason.
- **Record a size decision in the header when a harness crosses a lens bar.** The
  levers are the generator (enrolled harnesses only), the in-file entry-point
  pattern, cross-harness shared-logic extraction, and prompt-prose trimming. The
  last two stay blocked even for an enrolled harness: the generated artifact
  still cannot `import`, so fragments are shareable *within* a harness but never
  *across* them. Say which lever applies and why, **with measurements** — #718
  closed prose-trimming on a time series (string share was flat at 24%/44% across
  a 3x growth in `ship-issue`), not on an estimate. Settled per harness in #718.

<!-- contract: prelude-generator-coexistence -->

### A shared prelude does NOT ride on the fragment generator (#811)

Two mechanisms sound alike and are not interchangeable. **They stay separate**,
and the reason is structural rather than stylistic:

- `bin/generate-workflow-js.mjs` (#806) is a **within-harness** concatenation.
  Its `srcDirFor` resolves to `dirname(<artifact>)/workflow.src`, so a fragment
  is bound to one harness by construction.
- #586's prelude is a **cross-harness** copy-out — one source into N files.

The generated artifact still cannot `import` (#712), so a fragment is shareable
*within* a harness and **never** *across* harnesses; sharing `stableStringify`
between `ship-issue` and `code-reviewer` is exactly as impossible after #806 as
before it. Note also where the duplication sits: the two heaviest duplicators
(`code-reviewer` 14%, `orchestrate` 1%) are **not enrolled**, so even a generous
"just extend the generator" reading leaves the largest share untouched. Teaching
the generator about cross-harness sources is a different and larger design, not a
parameter.

**The coexistence rule, for the two enrolled harnesses only.** An enrolled
harness receives its prelude **as a fragment** —
`workflow.src/NN-prelude.js`, listed in `manifest.txt` — and **never** as a
banner region written into the generated artifact. A region written into the
artifact is overwritten by the next `just gen-workflow-js`, and until then
`tests/lint-workflow-js-generated.sh` fails the tree as stale: two tools fighting
over the same bytes.

Fragment form is what makes the two freshness gates unable to **disagree**: they
own **disjoint byte ranges** and compose in series — a prelude gate owns *source
→ fragment file*, the generator gate owns *fragments → artifact*. Neither is
weakened, and neither needs to know about the other.

<!-- contract: end-prelude-generator-coexistence -->

## Budget Discipline

- Define a `BUDGET_FLOOR` (40_000 is the house value) and stop spawning new
  fan-out work once `budget.total && budget.remaining() < BUDGET_FLOOR`, so a
  partial run returns its results instead of throwing mid-barrier. The harnesses
  run in a sandboxed engine with no shared-module import, so this constant is
  duplicated per file; `tests/lint-skills-agents.sh` pins every declaration to
  the house value, so a tuning change must update all harnesses (and the test's
  `HOUSE_BUDGET_FLOOR`) together.
- **Check the budget INSIDE each thunk**, not only while building the work list.
  A budget read during list construction is synchronous and never sees mid-flight
  exhaustion. (See `adversarial-review` Bug-Class Checklist: "Budget checked
  outside the barrier.")
- **Treat every `null` sub-result as partial**, not clean. A thrown agent (budget
  or otherwise) resolves to `null` in `parallel()`; set the run's
  `budget_exhausted`/partial flag when you see one, so a half-complete cycle is
  never reported as a clean pass.

## No Clock in the Sandbox — Bound Wall-Time at the Caller

A harness **cannot bound itself in wall-time**, and it is a recurring
mistake to try. The sandbox bans clocks and timers so per-step resume stays
deterministic: `Date.now()`, `new Date()`, and `Math.random()` all **throw**;
there is no `setTimeout`, no `Promise.race`-against-a-timer, and no `AbortSignal`
exposed to the script. The `agent()` API has **no per-agent timeout** option
either. And a *spinning* subagent emits no tokens, so it never advances
`budget.spent()` — the budget bounds *cost*, not *latency*, and cannot detect a
stuck agent.

So there is no in-harness "per-invocation deadline" or `timed_out` flag the
harness can set — a stuck `agent()` inside a `parallel()` barrier runs unbounded
in wall-time even far below the token cap (#224). Do **not** add a clock, a
timer, or a `timed_out` field a harness can never actually populate; that flag
would be dead code that reads as a working safeguard.

**The bound belongs to the caller.** Wall-time is only measurable in the Claude
turn that invokes the `Workflow` tool — it can invoke the harness as a
**background** task and poll `TaskOutput` against a threshold, then `TaskStop`
and recover partials from `<transcriptDir>/journal.jsonl`. The ship-issue skill
does exactly this via `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` +
`plugins/workflow/scripts/recover-journal-partials.sh`, mirroring the
`LIBRARIAN_CI_WAIT_TIMEOUT` CI-wait loop. When a harness needs a latency bound,
document it as a caller responsibility, not a harness feature.

**And give the caller a helper, not arithmetic to do.** "Caller responsibility"
is where both of those bounds first went wrong: each was introduced as prose
telling the model to track elapsed time, compare it to a threshold, count
extensions, and stop at the ceiling. A model deep in a review cycle does not
reliably do that — three golems wedged unbounded before #327, and the CI-wait
pair was read by no code at all until #588. Both now **call** a script
(`workflow-wall-timeout.sh`, `ci-wait-timeout.sh`; shared arithmetic in
`threshold-check.sh`) that returns a `continue|extend|stop|checkpoint` verdict.
A threshold a model must apply by hand is not a bound — it is a suggestion that
reads like one.

## Findings & Keying

- When findings are keyed across steps (rescore, classify, dedup), stamp a
  **unique `ref`** on each finding before keying — include a per-finding index
  (`${file}:${line}:${category}#${i}`), never the bare triple. Two findings on
  one line otherwise collide and overwrite each other's score/disposition.
- Tell the keyed step to copy the `ref` verbatim; do not have it reconstruct the
  ref from other fields.

## Null-Resilience & Observability

- Log every dropped sub-result, distinguishing a deliberate budget skip from an
  agent failure. A silent `.filter(Boolean)` makes a failed item vanish — and a
  missing row reads as "done/gone" to the human.
- On a failed classify/dispatch that produces no actionable detail, emit a
  synthetic escalation/whole-item entry so the failure is visible, never silent.

## Safety

- **Read-only review harnesses never push, commit, or edit.** State the read-only
  contract in the prompt; applying fixes is the calling skill's job.
- **Validate any value interpolated into an auto-approving command** (numeric /
  allowlist) before it reaches `--dangerously-skip-permissions`, `eval`, or a
  shell. (Bug-Class Checklist: "Unvalidated interpolation.")
- A consent/escape-hatch that skips review must require a second explicit consent
  under autonomy. (Bug-Class Checklist: "Single-consent autonomy escape-hatch.")

## Adversarial Self-Review

Before shipping a harness, apply the **`adversarial-review`** skill's Bug-Class
Checklist to it. Most harness bugs (ref collisions, budget-outside-barrier,
silent drops, unsafe interpolation) are caught by that one pass.

## Validation

- `node --check workflow.js` — the script must parse (it is plain JS, not TS).
- Every `agentType` is namespaced `<plugin>:<name>` and resolves to
  `plugins/<plugin>/agents/<name>.md` — a bare name throws under the Workflow
  tool. Enforced by `tests/lint-skills-agents.sh`.
- Trace each `agent()` mode against the agent definition it drives — the modes
  named in prompts must match the agent's documented modes.
- Confirm the agent contract doc matches EVERY dispatch path (per-file harness
  AND any direct single-agent dispatch).

## When to Use

- Writing or reviewing a `workflow.js` harness
- Designing the agent contract a harness drives

## When NOT to Use

- Writing the subagent itself — use `agent-authoring`
- Writing a skill with no harness — use `skill-authoring`
