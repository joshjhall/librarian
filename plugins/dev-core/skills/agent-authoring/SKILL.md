---
description: Guidelines for writing high-quality Claude Code agents and subagent definitions. Use when creating new agents, reviewing existing agents, or designing multi-agent workflows.
---

# Agent Authoring

**Detailed reference**: See `patterns.md` in this skill directory for a
copy-pasteable agent template, frontmatter reference, good/bad examples,
model selection guide, and review checklist. Load it when writing or
reviewing an agent.

## Agent Structure

Agents are markdown files with YAML frontmatter (configuration) and a body
(system prompt). The body is the ONLY prompt the agent receives — agents do
not inherit the full Claude Code system prompt.

- `name` (required): lowercase with hyphens, matches directory name
- `description` (required): tells Claude when to delegate — primary trigger
- `tools`: allowlist of tools the agent can use (inherits all if omitted)
- `model`: `haiku`, `sonnet`, `opus`, `fable`, a full model ID (e.g.
  `claude-opus-4-8`), or `inherit` (default: `inherit`). The tier aliases
  auto-track the latest generation — `sonnet`→Sonnet 5, `opus`→Opus 4.8,
  `fable`→Fable 5 — so an alias never needs a version bump when a new model
  ships. Pin a full ID only when you deliberately want to freeze a generation.
- Other fields: `disallowedTools`, `permissionMode`, `maxTurns`, `skills`,
  `mcpServers`, `hooks`, `memory`

## Description Field (Critical)

Claude uses the description to decide whether to delegate a task. A vague
description causes missed delegations or false triggers.

- Must state WHAT the agent does AND WHEN to use it
- Include "use proactively" if the agent should auto-trigger
- Include key terms users would mention when the agent should activate

```yaml
# Bad — too vague
description: Helps with code

# Bad — what but not when
description: Reviews code quality

# Good — what + when + proactive trigger
description: Expert code reviewer. Use proactively after writing or modifying code.
```

## System Prompt Design

The body is the agent's entire instruction set. Write it as a direct briefing.

- **Open with role and purpose** — one sentence establishing identity
- **Define the workflow** — numbered steps the agent follows when invoked
- **Specify output format** — how results should be structured
- **Include red flags / checklists** — concrete items to check, not vague goals
- Assume competence — skip fundamentals the model already knows
- Be specific: real commands, real file patterns, real examples

## Tool Scoping

Start restrictive, expand as needed. Every unnecessary tool is a risk.

- **Read-only agents** (reviewers, researchers): `Read, Grep, Glob, Bash`
- **Editing agents** (fixers, refactorers): add `Edit` or `Write`
- **Full-capability agents**: omit `tools` to inherit all
- Use `disallowedTools` to block specific tools from inherited set
- Use `hooks` for conditional restrictions (e.g., read-only SQL queries)

## Model Selection

Match the model to the task's complexity. **Quality compounds** — bad
exploration produces bad plans produces bad implementation. Escalate the tier
when errors propagate downstream.

| Model     | Use when                                              | Rationale                                       |
| --------- | ----------------------------------------------------- | ----------------------------------------------- |
| `haiku`   | Fast lookups, simple checks, high-frequency ops       | Mechanical work, no judgment calls              |
| `sonnet`  | Pattern matching, most agents — the balanced default  | Sonnet 5: good quality for structured tasks     |
| `opus`    | Implementation, architecture, most reasoning work     | Opus 4.8: strong reasoning, lighter than fable  |
| `fable`   | Deep reasoning where errors are expensive             | Fable 5: security audits, review verification, orchestration — priciest, reserve for compounding gates |
| `inherit` | Same model as the conversation                        | Let the caller decide                           |

Default to `sonnet` (the balanced tier) unless the agent does purely mechanical
work (use `haiku`), does implementation or most reasoning work (use `opus`), or
is a security/review-verification/orchestration gate where a wrong call is
expensive and quality compounds (use `fable`, the priciest tier — reserve it).
Note the two senses of "default": the frontmatter field defaults to `inherit`
when omitted, but when you DO pick a tier, `sonnet` is the recommended starting
point. See `patterns.md` — **Model Tiering Guide** for the full decision
framework.

## MUST NOT Restrictions

Document workflow-level prohibitions in the agent's `## Restrictions` section.
Format: `MUST NOT` + verb + rationale. These prevent agents from overstepping
their role in the pipeline.

Every agent MUST have a `## Restrictions` section. Derive restrictions from:

1. **Role boundary** — what the agent observes vs what it modifies
1. **Pipeline position** — what comes before/after this agent in the workflow
1. **Escalation triggers** — when the agent must hand off to a human or another agent

Examples by role:

- **Read-only agents** (reviewers, auditors): MUST NOT edit files, create
  commits, or apply fixes — observe and report only
- **Write agents** (refactorer, test-writer): MUST NOT change behavior
  (refactorer) or modify production code (test-writer)
- **Pipeline agents** (issue-writer, rebase-agent): MUST NOT take actions
  outside their pipeline stage — issue-writer creates issues, not PRs;
  rebase-agent resolves trivial conflicts, not logic changes

### Workflow Gate Awareness

Agents that participate in pipelines should document which gates they respect:

- **Pre-condition**: what must be true before this agent runs (e.g.,
  "all scanners must complete before issue-writer dispatches")
- **Post-condition**: what this agent guarantees when it finishes (e.g.,
  "all findings conform to finding-schema.md")
- **Escalation**: when and how this agent hands off (e.g., "non-trivial
  conflicts escalate to human orchestrator")

See `patterns.md` — **Safety Constraints Template** for a copy-pasteable block.

For an agent driven by a `workflow.js` harness, apply the `adversarial-review`
skill (its Bug-Class Checklist) to the harness before shipping — most harness
bugs (ref collisions, budget-outside-barrier, silent drops, unsafe
interpolation) surface there. See also the `workflow-authoring` skill.

## Safety Constraints

For every tool in the `tools:` list, document WHY it is granted. For every
tool deliberately excluded, document WHY it is denied. This rationale helps
reviewers verify the agent's access is intentional, not accidental.

## Prose Trimming

Remove anything the model already knows or the code already enforces. Apply
the deletion test: if removing a line changes no agent behavior, delete it.
Agent prompts that restate model knowledge waste context tokens and dilute
the instructions that actually matter.

## Orchestrator Extension

See `patterns.md` — **Orchestrator Extension Patterns** section. Load it when
building an agent that participates in a multi-agent pipeline (e.g., audit
scanners for `codebase-audit`, sub-reviewers for `code-reviewer`).

## Core Principles

- **One task per agent** — don't mix reviewing with fixing with testing
- **Minimal viable tools** — grant only what the task requires
- **Isolation preserves context** — agent output stays in its own window;
  only the summary returns to the main conversation
- **Description drives delegation** — invest more time in description than
  in the system prompt itself
- **No nesting** — subagents cannot spawn other subagents; chain from the
  main conversation instead

## Anti-Patterns

- Overlapping agents with similar descriptions (confuses delegation)
- System prompts that restate what the model already knows
- Granting all tools when the agent only needs read access
- Missing output format (agent returns unstructured walls of text)
- Prompts full of if-then logic instead of clear heuristics
- No workflow steps (agent doesn't know where to start)

## When to Use

- Creating a new specialized agent for a repeatable task
- Reviewing an existing agent's prompt, tools, or model choice
- Designing multi-agent workflows with delegation chains

## When NOT to Use

- Writing skills (use `skill-authoring` skill instead)
- One-off tasks that don't warrant a reusable agent
- Tasks that need the main conversation's full context
