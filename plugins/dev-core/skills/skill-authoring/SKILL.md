---
description: Guidelines for writing high-quality Claude Code skills and AI agent instructions. Use when creating new skills, reviewing existing skills, or writing CLAUDE.md / rules files for any AI coding tool.
---

# Skill Authoring

**Detailed reference**: See `patterns.md` in this skill directory for a
copy-pasteable skill template, good/bad examples, a review checklist, and
cross-tool compatibility notes. Load it when writing or reviewing a skill.

## Skill Structure

- YAML frontmatter with `description:` — this is the trigger mechanism
- H1 title, H2 sections, bullet-point dominant format
- Companion files for detailed reference (one level deep only — no chains)
- Reference companions with: "See `file.md` — load it when \<specific situation>"

## Core Principles

- **Conciseness is survival** — every token competes with conversation context;
  shorter skills get retained longer in the context window
- **Assume competence** — only document what Claude doesn't already know;
  skip language fundamentals, standard library usage, common patterns
- **Specificity over generality** — concrete commands, real paths, real examples;
  "run `pytest tests/ -x`" not "run the test suite"
- **Progressive disclosure** — essential rules in SKILL.md, details in companions
- **Match freedom to fragility** — prescriptive for error-prone operations
  (git, deployment), flexible for creative work (naming, architecture)

## Writing Effective Content

- Lead with actionable instructions, not explanations
- Use bullet points over prose paragraphs
- Show good/bad examples with concrete code, not descriptions
- Include "When to Use" and "When NOT to Use" sections
- Every command must be copy-pasteable and work exactly as written
- Replace vague pronouns ("it", "this", "that") with specific terms

## Description Field (Critical)

The `description:` in frontmatter is the primary trigger for skill selection.
Claude uses it to decide which skills to load from potentially hundreds.

- Must include both WHAT the skill does AND WHEN to use it
- Write in third person ("Processes Excel files" not "I help with Excel")
- Include key terms users would mention when the skill should activate
- Keep under ~200 characters — long descriptions get truncated in selection

```yaml
# Bad — too vague, missing "when"
description: Helps with testing

# Bad — first person, no trigger context
description: I know how to write good tests for Python projects

# Good — what + when + key terms
description: Test-first development patterns and framework conventions. Use when writing tests, adding coverage, or setting up test infrastructure.
```

## Scoping

- One clear domain per skill — don't mix testing with deployment
- **Too broad**: covers everything, nothing is actionable (rarely triggers well)
- **Too narrow**: only applies to rare edge cases (rarely triggers at all)
- **Good scope**: a topic where Claude consistently needs project-specific guidance

## Anti-Patterns

- Explaining fundamentals Claude already knows (wastes context tokens)
- Vague instructions ("write clean code") instead of specific ones
  ("use Zod for request body validation in API handlers")
- Over-length skills that bury important information in noise
- Duplicating what linters, formatters, or the codebase already enforce
- Too many "don't" statements without positive alternatives
- Missing verification steps (how to confirm the skill worked)
- Deeply nested companion files referencing other companion files

## Metadata File (metadata.yml)

Every skill directory should include a `metadata.yml` alongside SKILL.md.
This provides machine-readable metadata for tooling (label sync, CI,
documentation generators).

- **Required fields**: `name`, `version`
- **Optional fields**: `labels`, `required_tools`, `required_permissions`,
  `required_mcps` — use empty arrays (`[]`) when not applicable
- This file is informational — it does not change skill behavior at runtime
- See `patterns.md` for the full schema and an example

## Companion Files

- Use when SKILL.md would exceed ~120 lines
- No YAML frontmatter — plain markdown only
- Open with a one-line purpose statement referencing SKILL.md
- Include checklists, decision tables, and worked examples
- SKILL.md must say when to load the companion (not just that it exists)

## Token Efficiency

Every sentence must add information Claude cannot derive from the codebase,
git history, or its own training data.

- **Deletion test**: if removing a line changes no agent behavior, delete it
- Prefer structured directives (tables, bullets) over narrative prose
- Move reference material to companion files — SKILL.md is for directives
- Measure: a well-trimmed skill is 40-80% shorter than its first draft

## Certainty Grading

For skills that produce actionable findings (audits, reviews, linters), grade
each finding by detection confidence:

| Level    | Detection Method    | Action                | Example                    |
| -------- | ------------------- | --------------------- | -------------------------- |
| CRITICAL | Exact pattern match | Auto-fix with warning | Hardcoded secret in source |
| HIGH     | Deterministic rule  | Auto-fix              | Empty catch block          |
| MEDIUM   | Heuristic + context | Flag for human review | Function too complex       |
| LOW      | LLM judgment only   | Report only           | Possible over-engineering  |

The certainty object JSON structure (required on all findings):

```json
{
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  }
}
```

Fields: `level` (CRITICAL/HIGH/MEDIUM/LOW), `support` (evidence count),
`confidence` (0.0-1.0), `method` (deterministic/heuristic/llm). See
`codebase-audit/finding-schema.md` for the full schema.

Not all skills need certainty grading — skip for skills that provide guidance
rather than findings (e.g., `git-workflow`, `documentation-authoring`).

## Workflow Safety

For skills with multi-step workflows (pipelines, audit flows, shipping
processes), add safety assertions at phase boundaries:

1. **Gate assertions** — pre-condition checks that must pass before advancing:

   - Pre-ship: test suite passes before PR creation
   - Pre-dispatch: inputs validated before fanning out to sub-agents
   - Pre-aggregation: all sub-tasks completed before merging results

1. **Blocking vs advisory gates**:

   - **Blocking**: the workflow MUST NOT proceed if the gate fails (e.g.,
     tests must pass before PR creation)
   - **Advisory**: warn the user but allow them to proceed (e.g., tests
     should pass before commit-only shipping)

1. **MUST NOT restrictions** — document what the skill must never do,
   following the same pattern as agent restrictions. See
   `agent-authoring/SKILL.md` § MUST NOT Restrictions for the template.

Not all skills need workflow gates — skip for simple skills that don't have
multi-step workflows.

## Code-Based Enforcement

When a skill detects problems, prefer deterministic detection over LLM:

1. **Phase 1 (regex/AST)**: Zero LLM cost, 100% reliable for known patterns
1. **Phase 2 (context-aware LLM)**: For judgment calls — complexity, design
   quality, over-engineering
1. **Phase 3 (external tools)**: CLI tools (`eslint`, `pylint`, `jscpd`) when
   available in the environment

Reserve LLM analysis for findings that genuinely require reasoning.

## Orchestrator Extension

See `patterns.md` — **Orchestrator Extension Patterns** section. Load it when
building a skill that integrates with `codebase-audit`, `next-issue`, or any
multi-agent pipeline.

## Validation

Before shipping a skill, verify:

- **Cold-start test**: fresh session + only this skill + a task — does it work?
- **Trigger test**: does the skill activate for the right user requests?
- **Negative test**: does the skill stay silent for unrelated requests?
- **Iteration**: observe agent behavior, identify gaps, refine, retest
- **Adversarial review**: for a skill that produces findings or drives a
  workflow, apply the `adversarial-review` skill (its Bug-Class Checklist)
  before shipping
