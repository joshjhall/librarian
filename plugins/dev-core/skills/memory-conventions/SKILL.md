---
description: Two-tier memory conventions for .claude/memory/ — long-term committed team knowledge vs short-term gitignored session state. Use when deciding where to store persistent information.
---

# Memory Conventions

This project uses a two-tier memory system under `.claude/memory/`.

## Long-term Memory (committed to git)

**Path**: `.claude/memory/*.md` (root level, not in `tmp/`)

Store durable team knowledge that benefits all developers:

- Architecture decisions and trade-offs
- Project conventions not captured by linters
- Domain terminology and stakeholder context
- Onboarding context not obvious from code

These files are committed and shared across the team.

## Short-term Memory (gitignored)

**Path**: `.claude/memory/tmp/`

Store ephemeral per-session state:

- Workflow tracking (e.g., `next-issue-101.json` for issue #101)
- Temporary analysis or debug notes
- State that survives context resets but not rebuilds

This directory is gitignored — nothing here is committed.

## Decision Guide

| Information type              | Tier       | Example path                             |
| ----------------------------- | ---------- | ---------------------------------------- |
| "We chose X because Y"        | Long-term  | `.claude/memory/architecture-auth.md`    |
| "Currently working on #101"   | Short-term | `.claude/memory/tmp/next-issue-101.json` |
| "API naming convention"       | Long-term  | `.claude/memory/conventions-api.md`      |
| "Debug session scratch notes" | Short-term | `.claude/memory/tmp/debug-session.md`    |

## Do NOT Store

- Code patterns derivable from reading the codebase
- Git history (use `git log` / `git blame`)
- Anything already documented in `CLAUDE.md`
- Fix recipes (the fix is in the code, context in the commit message)
