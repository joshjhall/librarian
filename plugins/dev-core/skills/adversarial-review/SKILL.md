---
description: Adversarial review method for skills, agents, and workflow.js harnesses. Use when creating or reviewing AI artifacts, or auditing the repo's automation for correctness, safety, and silent-failure bugs.
---

# Adversarial Review

A repeatable method for reviewing AI artifacts — skills, agents, and `workflow.js`
harnesses — for correctness, safety, and silent failures. Use it at **creation
time** (self-review before shipping) and at **audit time** (reviewing the repo's
automation). The authoring skills (`skill-authoring`, `agent-authoring`,
`workflow-authoring`) and the `check-ai-config` harness-logic lens all reference
this skill — it is the single source for the method and the Bug-Class Checklist.

## The Method

- **Read every executable surface, not just frontmatter.** Bugs live in the
  `workflow.js` harness, embedded shell (heredocs, entrypoint scripts inside
  SKILL.md fences), regen/install commands, and the prompts that feed
  auto-approving tools — not in the description field. Frontmatter linting finds
  none of the bugs that matter.
- **Verify, don't trust.** Before flagging a suspicious construct, confirm it is
  actually wrong — trace it through both code paths. A flagged-but-correct
  finding wastes the author's time and erodes trust in the review. *Worked
  example:* `git checkout --ours` looked wrong for a rebase, but tracing it shows
  `--ours` = the integration target in **both** a merge (current branch) and a
  rebase-onto-base (base, since HEAD=base while replaying) → not a bug.
- **Escalate, don't guess.** When automation cannot resolve something safely, the
  correct behavior is to escalate to a human, not to apply a best-guess. Flag any
  auto-resolution that guesses. *Worked example:* string-comparing non-semver
  versions ("1.10" sorts before "1.9") → must escalate, not guess.
- **Hunt recurring bug classes across siblings.** The same bug usually recurs in
  sibling artifacts built from a shared template. When you find one, grep every
  sibling for it. *Worked example:* the finding-ref collision existed in **two**
  review harnesses; fixing one without the other leaves the system inconsistent.
- **Retract false positives.** When evidence disproves a finding, back it out
  explicitly and say why — a retracted finding is a successful review, not a
  failure. *Worked examples:* "shell files flood the missing-test scanner" was
  wrong (`*.sh` is already in the skip policy); "add an acknowledged_count to the
  summary" was wrong (it forks a schema shared by other scanners).
- **Check consistency seams.** When a change adds a flag, gate, or field, verify
  every consumer and doc was updated to match — a half-applied change is its own
  bug. *Worked example:* a second-consent merge gate added in one skill but not
  passed through by the skill that launches it.

## Bug-Class Checklist

Apply each row to every artifact under review. These are the concrete failure
modes this method has caught; treat the "Detect" column as the question to ask.

| Bug class | Why it bites | Detect |
| --------- | ------------ | ------ |
| **Non-unique finding refs** | Two findings sharing `file:line:category` collide in a keyed map, so one silently inherits the other's score/disposition | Does each finding carry a UNIQUE id including a per-finding index (`#${i}`), not just the triple? |
| **Budget checked outside the barrier** | Budget read only while *building* a parallel barrier (synchronously, before `await`) never sees mid-flight exhaustion; a partial run looks complete | Is the budget re-checked inside each thunk, AND is every `null` sub-result treated as a partial/non-clean cycle? |
| **Single-consent autonomy escape-hatch** | A review-skipping fast-path (auto-merge) gated by one env var fires unattended when autonomy sets that var from the environment | Does any path that skips review/human-gate require a SECOND explicit consent under autonomy? |
| **Supply-chain regen** | `npm install` / `pnpm install` / `composer update` run install lifecycle scripts and drift unrelated deps while integrating *another* branch | Are regen commands lockfile-only / `--ignore-scripts` / `--no-scripts`? Is codegen limited to project-declared generators? |
| **Unvalidated interpolation into auto-approving tools** | An untrusted value spliced into a `--dangerously-skip-permissions` / `eval` / shell command can break out and run arbitrary code | Is every interpolated value validated (numeric / allowlist) before it reaches an auto-approving command? |
| **Silent result drops** | `.filter(Boolean)` on a parallel result with no log makes failed sub-results vanish — a dropped row reads as "done/gone" | Is every null/failed sub-result logged (distinct from a deliberate budget skip), not silently filtered away? |
| **Prompts that assert false facts on fallback** | A prompt that says "certainty already rescored" when the rescore step failed makes the next step trust producer self-grades as authoritative | Are prompt claims conditional on the step having actually run? |
| **Doc contradicts the real dispatch path** | An agent doc that says "always driven per-file by the harness" misleads when the primary caller dispatches it directly with the whole list | Does the doc match how the artifact is ACTUALLY invoked on every path, not just one? |
| **Extending a shared schema in one consumer** | Adding a field to a schema that other artifacts also emit forks the contract | Is this schema shared before extending it? If shared, change it everywhere or not at all. |
| **Parallel verify collisions** | N items each running the full suite in parallel waste budget and collide on shared ports / test DBs | Is verification scoped to the changed unit, falling back to the full suite only when no scoped check exists? |

## Certainty Grading

Grade findings HIGH / MEDIUM / LOW by detection confidence, and retract findings
that evidence disproves. Reuse the certainty object and grading rubric from
`skill-authoring` SKILL.md § Certainty Grading — do not duplicate it here.

## When to Use

- Self-reviewing a new skill, agent, or `workflow.js` harness before shipping
- Auditing the repo's automation (the `check-ai-config` harness-logic lens calls
  this checklist)
- Reviewing a PR that changes any AI artifact

## When NOT to Use

- Reviewing ordinary application code — use `code-review` / the `code-reviewer`
  agent (this skill is scoped to AI artifacts and their harnesses)
- Pure frontmatter / structural validation — `check-ai-config`'s deterministic
  pre-scan already covers that
