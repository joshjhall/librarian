# Agent Authoring — Patterns & Examples

Reference companion for `SKILL.md`. Load this when writing a new agent,
reviewing an existing agent, or designing agent workflows for cross-tool
compatibility.

---

## Agent Template

Copy-pasteable skeleton for a new agent:

```markdown
---
name: <agent-name>
description: <What it does and when to delegate — include key trigger terms>
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a <role> specializing in <domain>.

When invoked:

1. <First step — gather context>
2. <Second step — analyze or act>
3. <Third step — produce output>

## Checklist

- <Concrete item to check or do>
- <Another concrete item>

## Output Format

<How to structure the response — severity levels, sections, etc.>
```

---

## Frontmatter Reference

| Field             | Required | Default   | Purpose                                           |
| ----------------- | -------- | --------- | ------------------------------------------------- |
| `name`            | Yes      | —         | Unique ID (lowercase, hyphens), matches directory |
| `description`     | Yes      | —         | When Claude should delegate to this agent         |
| `tools`           | No       | All       | Allowlist of available tools                      |
| `disallowedTools` | No       | None      | Tools to deny from inherited set                  |
| `model`           | No       | `inherit` | `haiku`, `sonnet`, `opus`, or `inherit`           |
| `permissionMode`  | No       | `default` | Permission handling mode                          |
| `maxTurns`        | No       | —         | Max agentic turns before stopping                 |
| `skills`          | No       | None      | Skills to preload into the agent's context        |
| `mcpServers`      | No       | None      | MCP servers available to the agent                |
| `hooks`           | No       | None      | Lifecycle hooks scoped to this agent              |
| `memory`          | No       | None      | Persistent memory: `user`, `project`, or `local`  |

---

## Description Field — Good vs Bad

| Quality | Description                                                                            | Problem / Strength                        |
| ------- | -------------------------------------------------------------------------------------- | ----------------------------------------- |
| Bad     | `Helps with code`                                                                      | Too vague, no task or trigger             |
| Bad     | `Code quality agent`                                                                   | No "when", just a label                   |
| OK      | `Reviews code for quality`                                                             | Has task but no trigger                   |
| Good    | `Expert code reviewer. Use proactively after writing or modifying code.`               | Task + proactive trigger                  |
| Good    | `Debugging specialist for errors and test failures. Use when encountering any issues.` | Task + clear trigger condition            |
| Good    | `Generates comprehensive tests for existing code`                                      | Task implies trigger (after code written) |

---

## System Prompt — Good vs Bad

### Opening

**Bad — too vague, no structure:**

```markdown
Review code and find issues. Make it better.
```

**Good — role, workflow, specifics:**

```markdown
You are a senior code reviewer ensuring high standards of quality and security.

When invoked:

1. Run git diff to see recent changes
2. Focus on modified files
3. Begin review immediately
```

### Checklists

**Bad — generic, Claude already knows these:**

```markdown
- Write clean code
- Follow best practices
- Handle errors properly
```

**Good — specific red flags to check:**

```markdown
- Generic base exceptions instead of specific error types
- Exceptions with no structured context (just a message string)
- Async operations without timeout limits
- Batch operations that stop entirely on first failure
```

### Output Format

**Bad — no structure specified:**

```markdown
Tell me what you found.
```

**Good — clear format with severity:**

```markdown
Provide feedback organized by priority:

- Critical issues (must fix)
- Warnings (should fix)
- Suggestions (consider improving)

For each finding, include the file and line, issue description, and fix.
Skip purely stylistic preferences with no impact on correctness.
```

---

## Tool Scoping Patterns

| Agent Type  | Recommended Tools               | Rationale                      |
| ----------- | ------------------------------- | ------------------------------ |
| Reviewer    | `Read, Grep, Glob, Bash`        | Read-only, no accidental edits |
| Researcher  | `Read, Grep, Glob, WebFetch`    | Exploration only               |
| Debugger    | `Read, Edit, Bash, Grep, Glob`  | Needs to fix code              |
| Test writer | `Read, Write, Bash, Grep, Glob` | Creates new test files         |
| Refactorer  | `Read, Edit, Bash, Grep, Glob`  | Modifies existing code         |
| Coordinator | `Task(worker, researcher)`      | Only spawns specific agents    |

For conditional restrictions, use hooks:

```yaml
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate-command.sh"
```

---

## Advanced Features

### Persistent Memory

Use `memory` when the agent should learn across sessions:

```yaml
---
name: code-reviewer
memory: user # Recommended default scope
---

As you review code, update your agent memory with patterns,
conventions, and recurring issues you discover.
```

| Scope     | Location                             | Use when                                 |
| --------- | ------------------------------------ | ---------------------------------------- |
| `user`    | `~/.claude/agent-memory/<name>/`     | Learnings apply across all projects      |
| `project` | `.claude/agent-memory/<name>/`       | Knowledge is project-specific, shareable |
| `local`   | `.claude/agent-memory-local/<name>/` | Project-specific, not version-controlled |

The agent auto-reads the first 200 lines of `MEMORY.md` in its memory
directory. Prompt the agent to consult and update its memory explicitly.

### Skill Preloading

Use `skills` to inject domain knowledge into the agent's context:

```yaml
---
name: api-developer
skills:
  - error-handling
  - testing-patterns
---

Implement API endpoints. Follow the patterns from the preloaded skills.
```

Skills are injected as full content, not just made available. Subagents
do not inherit skills from the parent conversation — list them explicitly.

---

## Review Checklist

Before shipping an agent, verify each item:

- [ ] `name:` is lowercase with hyphens, matches the directory name
- [ ] `description:` includes what + when (trigger terms present)
- [ ] System prompt opens with role and purpose (one sentence)
- [ ] Workflow steps are numbered and concrete
- [ ] Output format is specified
- [ ] Tools are scoped to minimum necessary (not all tools)
- [ ] Model matches the task (haiku for fast, sonnet for balanced, opus for complex)
- [ ] No fundamentals the model already knows
- [ ] Red flags / checklists use specific items, not vague goals
- [ ] Agent tested with a real task to verify delegation triggers
- [ ] MUST NOT restrictions documented for workflow-level safety
- [ ] Tool rationale documented (why each tool is granted or excluded)
- [ ] Prose trimming verified: no line removable without behavior change
- [ ] Agent quality: passes 14-pattern checklist (see below)

---

## Cross-Tool Compatibility

Agent definitions follow conventions that map across tools:

| Concept       | Claude Code                   | Cursor                      | AGENTS.md (Codex)               |
| ------------- | ----------------------------- | --------------------------- | ------------------------------- |
| Location      | `~/.claude/agents/`           | `.cursor/agents/`           | `AGENTS.md` per directory       |
| Format        | YAML frontmatter + markdown   | YAML frontmatter + markdown | Plain markdown                  |
| Trigger       | `description:` field          | `description:` field        | Always loaded (directory scope) |
| Tool control  | `tools:` / `disallowedTools:` | Tool restrictions in config | Sandbox-based                   |
| Model control | `model:` field                | Model selection in config   | Model selection in config       |
| Scope         | User or project level         | Project level               | Directory hierarchy             |

### Portable Patterns

- Role + workflow + checklist structure
- Numbered steps for the agent to follow
- Concrete red flags and items to check
- Severity-based output format
- Tool restrictions documented alongside the prompt

### Converting Between Formats

1. Keep the system prompt (body) unchanged — it works everywhere
1. Adapt frontmatter to the target tool's metadata format
1. For AGENTS.md (always loaded), move trigger context into prose
   since there's no description field for selective loading

---

## Agent Quality Patterns

14-pattern checklist for agent quality. Each pattern maps to a finding from
the agentsys evaluation (#304). Use during agent review or creation.

| #  | Pattern                 | Criterion                                                                           |
| -- | ----------------------- | ----------------------------------------------------------------------------------- |
| 1  | Model assignment        | Model tier matches task complexity (see Model Tiering Guide below)                  |
| 2  | Tool scoping            | Minimum viable tools — every tool has a documented rationale                        |
| 3  | Workflow enforcement    | Numbered steps with no ambiguous branching                                          |
| 4  | Safety constraints      | `## Restrictions` section with MUST NOT rules, tool rationale, and workflow gates   |
| 5  | Output schema           | Structured output format specified (JSON, severity tiers, sections)                 |
| 6  | Idempotency             | Same input produces same output on repeated invocation                              |
| 7  | Error boundaries        | Agent handles errors gracefully and returns structured error responses              |
| 8  | Batch strategy          | Large inputs define fan-out behavior (when/how to spawn sub-agents)                 |
| 9  | Description quality     | WHAT + WHEN + trigger terms in description field                                    |
| 10 | Prose density           | No line removable without changing agent behavior (deletion test)                   |
| 11 | Checklist specificity   | Red flags are concrete items, not vague goals                                       |
| 12 | Context isolation       | Agent output stays in its own window; only summary returns to caller                |
| 13 | Composability           | Output is consumable by downstream agents or orchestrators                          |
| 14 | Acknowledgment handling | Audit/review agents support inline suppression comments (e.g., `audit:acknowledge`) |

---

## Model Tiering Guide

Decision framework for choosing the right model tier. Key principle from the
agentsys evaluation: **quality compounds** — bad exploration → bad plan → bad
implementation. Use opus where errors propagate downstream.

### Decision Criteria

| Criterion            | → haiku          | → sonnet              | → opus                    |
| -------------------- | ---------------- | --------------------- | ------------------------- |
| Error propagation    | Errors are local | Errors are noticeable | Errors cascade downstream |
| Task structure       | Mechanical/rote  | Pattern-matching      | Requires reasoning        |
| Quality compounding  | No               | Moderate              | High                      |
| Invocation frequency | Very high        | Normal                | Low-moderate              |

### Decision Tree

1. Does the agent produce output that other agents consume? → Lean toward opus
1. Is the task mechanical (copy, format, look up)? → Use haiku
1. Is the task pattern-matching (review, scan, classify)? → Use sonnet
1. Does the agent make architectural or design decisions? → Use opus

### Real Examples from Our System

| Agent                | Model  | Rationale                                                        |
| -------------------- | ------ | ---------------------------------------------------------------- |
| `issue-writer`       | haiku  | Mechanical: renders template + calls CLI                         |
| `code-reviewer`      | sonnet | Orchestrates parallel sub-reviewers via Task                     |
| `test-writer`        | sonnet | Structured generation following test framework patterns          |
| `audit-architecture` | opus   | Architecture analysis quality compounds downstream               |
| `debugger`           | opus   | Root cause analysis benefits from deeper reasoning               |
| `audit-ai-config`    | opus   | Agent/skill quality analysis affects all downstream interactions |
| `skill-author`       | opus   | Quality compounds: bad skill → bad behavior across all uses      |
| `agent-author`       | opus   | Quality compounds: bad agent → bad output across all uses        |

### Model Tier and Deterministic Coverage

As `patterns.sh` deterministic coverage increases for a checker domain, the
LLM's role shrinks to residual heuristic and judgment categories. This shifts
the model tier needed:

| Deterministic Coverage | Recommended Tier | Rationale                                      |
| ---------------------- | ---------------- | ---------------------------------------------- |
| 100%                   | haiku            | LLM confirms/dismisses pre-scan results only   |
| > 75%                  | sonnet           | LLM handles a few heuristic categories         |
| < 50%                  | opus             | LLM performs most reasoning; quality compounds |

Use `bin/check-patterns-coverage.sh` to measure current coverage per domain.
As of initial measurement: 22/28 categories (78%) are covered by patterns.sh.
Four domains have 100% deterministic coverage (security, code-health,
deadlinks, staleness) and could potentially downgrade to haiku for the LLM
confirmation pass.

**Deferral note**: Do not change model tiers until check-\* skill migration is
complete. Coverage improvements from discrete code candidates (#338) may shift
several more categories to deterministic, enabling broader tier downgrades.

---

## Safety Constraints Template

Copy-pasteable block for documenting MUST NOT restrictions and tool rationale
in an agent definition. Insert after the role statement in the system prompt.

```markdown
## Restrictions

MUST NOT:

- <verb> — <rationale>
- <verb> — <rationale>

## Tool Rationale

| Tool      | Purpose                             | Why granted                      |
| --------- | ----------------------------------- | -------------------------------- |
| Read      | Read source files for analysis      | Core to the review workflow      |
| Grep      | Search for patterns across codebase | Needed for finding occurrences   |
| Glob      | Find files by name patterns         | Needed for file discovery        |
| Bash      | Run CLI commands (gh, glab, git)    | Platform interaction required    |
| ~~Edit~~  | ~~Modify files~~                    | Denied: this agent observes only |
| ~~Write~~ | ~~Create files~~                    | Denied: this agent observes only |
```

**Worked example** (from `audit-security`):

```markdown
## Restrictions

MUST NOT:

- Edit or write source files — you observe and report, never modify code
- Auto-fix findings below HIGH certainty — flag for human review instead
- Skip manifest files in scanning — config files often contain secrets

## Tool Rationale

| Tool | Purpose                         | Why granted                            |
| ---- | ------------------------------- | -------------------------------------- |
| Read | Read source files for analysis  | Core to security scanning              |
| Grep | Search for secret patterns      | Regex-based detection (Phase 1)        |
| Glob | Find config/env files           | Discovery of files to scan             |
| Bash | Run external tools if available | Phase 3 detection (eslint, etc.)       |
| Task | Fan out to batch sub-agents     | Large manifests need parallel scanning |
```

---

## Orchestrator Extension Patterns

When building an agent that plugs into an existing orchestrator, follow the
orchestrator's discovery mechanism, contracts, and naming conventions.

### Pattern 1: Scanner Agent for `codebase-audit`

The orchestrator globs `.claude/agents/audit-*/audit-*.md` and reads
frontmatter to build its scanner list. To create a new scanner:

1. **Name**: `audit-<domain>` (e.g., `audit-docker`, `audit-perf`)
1. **Directory**: `.claude/agents/audit-<domain>/audit-<domain>.md`
1. **Frontmatter**: `name` and `description` must be present (orchestrator
   reads these for routing)
1. **Model**: `sonnet` for the primary scanner; `haiku` for batch sub-agents
   dispatched via `Task` tool for manifests > 2000 lines
1. **Output**: JSON matching `finding-schema.md` — fields: `scanner`,
   `summary` (files_scanned, total_findings, by_severity), `findings` array
   (id, category, severity, title, description, file, line_start, line_end,
   evidence, suggestion, effort, tags, related_files), `acknowledged_findings`
1. **Categories**: `<scanner-name>/<slug>` format (e.g., `audit-docker/no-healthcheck`)
1. **Labels**: orchestrator auto-creates `audit/<category>` labels
1. **Override**: if your agent shares a name with a built-in scanner, the
   project-level agent takes precedence

### Pattern 2: Pipeline Agent for `next-issue` Chain

Agents that participate in the issue pipeline:

- Read/write state files at `.claude/memory/tmp/next-issue-{N}.json`
- JSON schema (version 2): `issue`, `title`, `phase`, `branch`, `plan`,
  `started`, `platform`, plus optional `checkpoint` object for context handoff
- Write `checkpoint` before phase transitions to preserve key decisions,
  modified/planned files, warnings, and next action across `/clear` resets
- Validate state before acting (issue still open, branch still exists)
- Delete state file after successful completion

### Pattern 3: Parallel Sub-Agent for Coordinator Dispatch

Agents dispatched in parallel by a coordinator (e.g., future `code-reviewer`
per #315):

- Receive a manifest (file list + context) as the task prompt
- Return structured JSON that the coordinator can merge/deduplicate
- Handle errors gracefully — return `"action": "error"` instead of crashing
- Keep output within the coordinator's expected schema
