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
  `tests/unit/claude/lint_skills_agents.sh`.
- **Discriminated agent modes**: drive one `agentType` in modes named in the
  prompt (`manifest`, `reviewer:<name>`, `rescore`, `merge`, …). The agent does
  one mode per call; the harness sequences them.
- **Typed schemas**: every `agent()` that returns data uses a JSON-Schema with
  `additionalProperties: false` and an explicit `required` list. Validation
  happens at the tool layer, so the model retries on mismatch.
- **`pipeline()` by default, `parallel()` only at a true barrier.** Use
  `parallel()` (a barrier) only when a later stage genuinely needs ALL prior
  results at once (dedup across the full set, early-exit on zero). Otherwise
  `pipeline()` — no wasted wall-clock.
- **Never call `workflow()`** — the one nesting level is reserved. A harness may
  itself run inside another (e.g. orchestrate → rebase-agent), so nesting throws.

## Budget Discipline

- Define a `BUDGET_FLOOR` (40_000 is the house value) and stop spawning new
  fan-out work once `budget.total && budget.remaining() < BUDGET_FLOOR`, so a
  partial run returns its results instead of throwing mid-barrier.
- **Check the budget INSIDE each thunk**, not only while building the work list.
  A budget read during list construction is synchronous and never sees mid-flight
  exhaustion. (See `adversarial-review` Bug-Class Checklist: "Budget checked
  outside the barrier.")
- **Treat every `null` sub-result as partial**, not clean. A thrown agent (budget
  or otherwise) resolves to `null` in `parallel()`; set the run's
  `budget_exhausted`/partial flag when you see one, so a half-complete cycle is
  never reported as a clean pass.

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
