# review-audit

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

Codebase audit and diff review: a periodic whole-codebase sweep
(`/codebase-audit`) and a shared `check-*` suite that runs both in audit mode
(over the whole tree) and review mode (over a diff). Findings are grouped by
category and turned into actionable GitHub/GitLab issues.

## Skills (9)

- `codebase-audit` — periodic full-codebase sweep (tech debt, security, test
  gaps, architecture, docs); creates grouped issues. Invoke with
  `/codebase-audit`.

The `check-*` suite is discovered by the `checker` agent; each skill pairs a
deterministic `patterns.sh` pre-scan with LLM analysis:

- `check-ai-config` — Claude Code config files (agents, skills, CLAUDE.md, MCP,
  hooks): structural issues, bloat, misconfigurations
- `check-code-health` — tech-debt markers, debug statements, empty error
  handlers, unused imports
- `check-security` — hardcoded secrets, injection, XSS, insecure crypto
- `check-docs-deadlinks` — broken internal/external links + missing anchors
- `check-docs-examples` — doc code examples vs actual source
- `check-docs-missing-api` — undocumented public APIs / complex functions
- `check-docs-organization` — doc structure, missing standard files, duplication
- `check-docs-staleness` — comments contradicting code, outdated refs, expired
  dates

## Agents (8)

The `codebase-audit` orchestrator fans out to per-dimension audit agents, then
hands grouped findings to the issue writer.

| Agent | Role |
| --- | --- |
| `checker` | Unified `check-*` runner — audit (codebase) and review (diff) modes |
| `audit-ai-config` | Claude Code artifact quality, drift, misconfigurations |
| `audit-architecture` | Circular deps, coupling, bus-factor, layer violations, god modules |
| `audit-code-health` | File length, complexity, duplication, dead code, naming |
| `audit-docs` | Stale comments, missing API docs, outdated READMEs |
| `audit-security` | OWASP patterns, secrets, insecure crypto, missing validation |
| `audit-test-gaps` | Untested APIs, missing error-path/edge-case tests |
| `issue-writer` | Turns grouped findings into issues; de-dupes before creating |
