# Skill Authoring — Patterns & Examples

Reference companion for `SKILL.md`. Load this when writing a new skill,
reviewing an existing skill, or adapting instructions for cross-tool
compatibility (Cursor rules, AGENTS.md, Windsurf rules).

---

## Skill Template

Copy-pasteable skeleton for a new skill:

```markdown
---
description: <What it does and when to use it — include key trigger terms>
---

# <Skill Name>

## <Primary Section>

- Actionable instruction with specific commands or patterns
- Another instruction with a concrete example

## When to Use

- Specific scenario where this skill applies
- Another scenario

## When NOT to Use

- Scenario where a different approach is better
- Edge case that looks relevant but isn't
```

---

## Metadata Template (metadata.yml)

Every skill directory should include a `metadata.yml` alongside SKILL.md:

```yaml
name: my-skill
version: "1.0"

# Labels this skill creates or requires on GitHub/GitLab issues
labels:
  - name: status/in-progress
    color: "0E8A16"
    description: An agent is working on this issue

# CLI tools the skill invokes (must be installed for the skill to work)
required_tools:
  - name: gh
    purpose: GitHub issue listing, labeling, PR creation
    install_hint: "Install the GitHub CLI (https://cli.github.com)"

# Auth permissions needed by the skill's tool invocations
required_permissions:
  - provider: github
    scopes:
      - repo
    notes: "gh auth login with 'repo' scope minimum"

# MCP servers the skill uses (if any)
required_mcps: []
```

For skills that don't use labels, tools, or permissions, use empty arrays:

```yaml
name: my-simple-skill
version: "1.0"

labels: []
required_tools: []
required_permissions: []
required_mcps: []
```

---

## Description Field — Good vs Bad

| Quality | Description                                                                                                                     | Problem / Strength                   |
| ------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| Bad     | `Helps with Python`                                                                                                             | Too vague, no trigger context        |
| Bad     | `I help write better code`                                                                                                      | First person, no domain              |
| Bad     | `Everything about testing, CI, coverage, mocking, assertions, fixtures, parametrize, snapshots, and more`                       | Too long, unfocused                  |
| OK      | `Python testing patterns`                                                                                                       | Has domain but missing "when to use" |
| Good    | `Python testing patterns and pytest conventions. Use when writing tests, debugging test failures, or setting up test fixtures.` | What + when + key terms              |
| Good    | `Git commit conventions and branch naming. Use when committing, creating branches, or preparing pull requests.`                 | Clear scope, actionable triggers     |
| Good    | `Error handling patterns, retry strategies, and resilience guidance`                                                            | Specific domains, implies when       |

---

## Content — Good vs Bad Examples

### Instructions

**Bad — vague, Claude already knows this:**

```markdown
- Write clean, maintainable code
- Use meaningful variable names
- Follow best practices
```

**Good — specific, project-relevant:**

```markdown
- Use Zod schemas for all API request validation
- Run `biome check --write .` before committing
- Place integration tests in `tests/integration/`, unit tests in `tests/unit/`
```

### Examples in Skills

**Bad — describes what good code looks like without showing it:**

```markdown
Use descriptive error messages that explain the problem.
```

**Good — shows concrete before/after:**

```markdown
Error messages must include what failed and how to fix it:
Bad: "Invalid input"
Good: "API key must be 32 hex characters, got 28: 'abc...xyz'"
```

### Commands

**Bad — ambiguous, may not work:**

```markdown
Run the linter to check your code.
```

**Good — copy-pasteable, exact:**

```markdown
Run `eslint --fix src/` to auto-fix lint issues.
```

---

## Review Checklist

Before shipping a skill, verify each item:

- [ ] `description:` includes what AND when (trigger terms present)
- [ ] SKILL.md is under 120 lines
- [ ] Bullet points dominate over prose paragraphs
- [ ] Every command is copy-pasteable and tested
- [ ] No fundamentals Claude already knows (language basics, stdlib)
- [ ] "When to Use" section has concrete scenarios
- [ ] "When NOT to Use" section prevents false triggers
- [ ] Specific terms replace vague pronouns ("it", "this")
- [ ] Companion files (if any) are referenced with "load when" guidance
- [ ] No nested companion chains (one level max from SKILL.md)
- [ ] Anti-patterns include positive alternatives, not just negatives
- [ ] At least one good/bad example pair for the primary use case
- [ ] `metadata.yml` exists with at least `name` and `version`
- [ ] `metadata.yml` lists all labels, tools, and permissions the skill uses
- [ ] Token efficiency: no line removable without behavior change
- [ ] Prompt quality: passes 16-pattern checklist (see below)

---

## Cross-Tool Compatibility

Skills follow conventions that work across multiple AI coding tools.
Adapting between them requires minimal changes:

| Concept  | Claude Code                 | Cursor                    | Windsurf         | AGENTS.md               |
| -------- | --------------------------- | ------------------------- | ---------------- | ----------------------- |
| Location | `~/.claude/skills/`         | `.cursor/rules/`          | `.windsurfrules` | `AGENTS.md`             |
| Format   | YAML frontmatter + markdown | Markdown (with metadata)  | Markdown         | Plain markdown          |
| Trigger  | `description:` field        | `globs:` / `description:` | Manual or auto   | Always loaded           |
| Scope    | Per-user or per-project     | Per-project               | Per-project      | Per-directory           |
| Nesting  | Companion files (1 level)   | Separate rule files       | Single file      | Per-directory hierarchy |

### Portable Patterns (work everywhere)

- Bullet-point instructions with specific commands
- Good/bad example pairs
- "When to Use" / "When NOT to Use" sections
- Tables for decision criteria
- Concrete file paths and real code examples

### Tool-Specific Patterns

- **Claude Code**: YAML frontmatter `description:` is critical for triggering
- **Cursor**: `globs:` patterns control which files activate the rule
- **Windsurf**: Single file, so brevity and prioritization are essential
- **AGENTS.md**: Always loaded in its directory scope — keep tightly scoped

### Converting Between Formats

When adapting a Claude skill to another tool:

1. Keep the core instructions and examples unchanged
1. Remove YAML frontmatter (replace with tool-specific metadata)
1. Adjust file paths if the tool uses different conventions
1. For single-file formats (Windsurf), merge companion content inline
   and cut aggressively for length

---

## Prompt Quality Patterns

16-pattern checklist for skill quality. Each pattern maps to a finding from
the agentsys evaluation (#304). Use during skill review or creation.

| #  | Pattern                | Criterion                                                                                  |
| -- | ---------------------- | ------------------------------------------------------------------------------------------ |
| 1  | Clarity                | Each instruction has a single unambiguous interpretation                                   |
| 2  | Structure              | H2 sections, numbered workflows, bullet checklists — scannable in 10 seconds               |
| 3  | Examples               | At least one concrete good/bad pair for the primary use case                               |
| 4  | Context / WHY          | Non-obvious rules include rationale so the agent can judge edge cases                      |
| 5  | Output format          | Skills producing output specify exact structure (JSON schema, severity tiers, etc.)        |
| 6  | Anti-patterns          | Every "don't" has a positive alternative showing what to do instead                        |
| 7  | Token efficiency       | No line removable without changing agent behavior (see SKILL.md § Token Efficiency)        |
| 8  | Certainty grading      | Finding-producing skills grade by detection confidence (CRITICAL/HIGH/MEDIUM/LOW)          |
| 9  | Code-based enforcement | Deterministic detection preferred over LLM where patterns are known                        |
| 10 | Progressive disclosure | Core rules in SKILL.md, reference details in companions                                    |
| 11 | Trigger terms          | `description:` field includes WHAT + WHEN + domain-specific keywords                       |
| 12 | Scope boundaries       | "When to Use" and "When NOT to Use" sections prevent false triggers and missed activations |
| 13 | Verification steps     | Skill includes how to confirm it worked (cold-start test, trigger test)                    |
| 14 | Model awareness        | Instructions appropriate for the target model tier (don't over-specify for opus)           |
| 15 | Idempotency            | Running the skill twice on the same input produces the same result                         |
| 16 | Composability          | Output is consumable by downstream skills, agents, or orchestrators                        |

---

## Orchestrator Extension Patterns

When building a skill that plugs into an existing orchestrator, follow these
patterns. Each orchestrator has its own discovery mechanism, contracts, and
naming conventions.

### Pattern 1: Scanner Discovery (`codebase-audit`)

The `codebase-audit` orchestrator discovers scanner agents by globbing
`.claude/agents/audit-*/audit-*.md`. To create a new scanner:

- **Naming**: directory and file must match `audit-<name>/audit-<name>.md`
- **Frontmatter**: `name` and `description` are read by the orchestrator for
  routing decisions
- **Output contract**: return JSON matching `finding-schema.md` (scanner,
  summary, findings array with id/category/severity/file/evidence/suggestion)
- **Categories**: use `<scanner-name>/<category>` slugs (e.g.,
  `audit-docker/missing-healthcheck`)
- **Labels**: the orchestrator creates `audit/<category>` labels automatically
- **Model**: use `sonnet` for primary scanner, `haiku` for batch sub-agents

### Pattern 2: State Handoff (`next-issue` → `next-issue-ship`)

Skills that chain across invocations use JSON state files with schema:

- **Path**: `.claude/memory/tmp/next-issue-{N}.json`
- **Schema**: JSON (version 2) with `issue`, `title`, `phase`, `branch`,
  `plan`, `started`, `platform` fields, plus optional `checkpoint` object
  for context handoff across `/clear` resets
- **Protocol**: the upstream skill writes the state file; the downstream skill
  reads and validates it; the downstream skill deletes it after completion
- **Checkpoint**: write `key_decisions`, `files_modified`, `files_planned`,
  `warnings`, and `next_action` before phase transitions
- **Validation**: check that the referenced issue is still open and the branch
  still exists before resuming

### Pattern 3: Parallel Dispatch (future `code-reviewer` #315)

Orchestrators that fan out to parallel sub-agents:

- **Dispatch**: one `Task` tool call per sub-agent, all in a single message
- **Input**: each sub-agent receives a manifest (file list + context)
- **Output**: structured JSON that the orchestrator can merge/deduplicate
- **Deduplication**: same file + same category + overlapping lines → merge
- **Aggregation**: cross-agent correlation rules merge related findings
