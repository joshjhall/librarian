# review-audit

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

Codebase audit and diff review: a periodic whole-codebase sweep
(`/review-audit:codebase-audit`) and a shared `check-*` suite that runs both in audit mode
(over the whole tree) and review mode (over a diff). Findings are grouped by
category and routed to a chosen **objective** — filed as actionable
GitHub/GitLab issues, or written as structured files under `./audit/{timestamp}/`
— always alongside a report summary. The audit never produces "nothing": every
run yields durable artifacts.

## Skills (10)

- `codebase-audit` — periodic full-codebase sweep (tech debt, security, test
  gaps, architecture, docs); creates grouped issues. Invoke with
  `/review-audit:codebase-audit`.

The `check-*` suite is discovered by the `checker` agent; each skill pairs a
deterministic `patterns.sh` pre-scan with LLM analysis:

- `check-ai-config` — Claude Code config files (agents, skills, CLAUDE.md, MCP,
  hooks): structural issues, bloat, misconfigurations. How it coexists with the
  external [agnix](https://github.com/agent-sh/agnix) linter is documented in
  [`docs/adr/0001-agnix-check-ai-config-boundary.md`](docs/adr/0001-agnix-check-ai-config-boundary.md)
- `check-code-health` — tech-debt markers, debug statements, empty error
  handlers, unused imports
- `check-security` — hardcoded secrets, injection, XSS, insecure crypto
- `check-lifecycle` — resource-lifetime defects: unreaped subprocesses,
  terminate-without-kill timeouts, unclosed handles, unpaired listeners
  (Swift/Python/JS/Go), plus LLM-only unjoined-worker + unbounded-growth
- `check-docs-deadlinks` — broken internal/external links + missing anchors
- `check-docs-examples` — doc code examples vs actual source
- `check-docs-missing-api` — undocumented public APIs / complex functions
- `check-docs-organization` — doc structure, missing standard files, duplication
- `check-docs-staleness` — comments contradicting code, outdated refs, expired
  dates

## Agents (9)

The `codebase-audit` orchestrator fans out to per-dimension audit agents, then
routes grouped findings to the objective writer — `issue-writer` (tracker) or
`artifact-writer` (files).

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
| `artifact-writer` | Writes findings + report to `./audit/{timestamp}/` (file-output counterpart) |

### Audit output objectives

`/review-audit:codebase-audit` asks (or you specify) where findings go:

- **`issues`** — file grouped findings as GitHub/GitLab issues (needs a
  detected tracker platform). This is the classic behavior.
- **`files`** — write `./audit/{timestamp}/findings.json` plus one markdown file
  per group, for repos without a tracker or teams that prefer in-tree,
  reviewable output.

A **report summary** (`./audit/{timestamp}-audit-report.md`) is written by
default in either case. Whether `./audit/` is committed or `.gitignore`d is left
to your workflow — the audit writes the files and does not touch `.gitignore`.
The old `dry-run` flag is removed; use `output: files` for a tracker-free run.
