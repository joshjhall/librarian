---
description: Detects stale documentation — comments contradicting code, outdated references, expired dates. Used by checker agent in audit and review modes.
---

# check-docs-staleness

Analyze documentation files and inline comments for staleness. You receive
pre-scan results (deterministic hits from `patterns.sh`) and file contents
from the checker agent.

**Companion files**: See `contract.md` for output format. See `thresholds.yml`
for configurable thresholds — load both when running analysis.

## Workflow

1. Review pre-scan results passed by the checker agent. For each:

   - Read the file context around the flagged line
   - **Confirm**: the finding is genuinely stale (keep certainty HIGH)
   - **Dismiss**: the finding is a false positive (explain why)
   - **Adjust**: change severity based on context

1. Analyze files not covered by pre-scan for additional staleness:

   - Comments describing behavior different from the code
   - References to removed variables, functions, files, or URLs
   - Parameter/return documentation mismatches
   - Outdated version numbers in documentation

1. Emit findings following `contract.md` format

## Categories

### stale-comment

Comments that describe behavior different from what the code does:

- Function descriptions not matching implementation
- Parameter docs for parameters that don't exist or have changed
- "Returns X" comments when the function returns something different
- Comments referencing removed variables, functions, or files

Severity: **high** (actively misleading — describes opposite behavior),
**medium** (outdated but not harmful)

Evidence: the comment text, what the code actually does

### outdated-reference

References in documentation pointing to non-existent targets:

- Old URLs, removed config options, renamed modules
- Version numbers that don't match current project state
- Installation commands referencing wrong packages or tools
- Badge URLs or CI links pointing to non-existent resources

Severity: **high** (installation/setup instructions are wrong),
**medium** (general reference is outdated)

Evidence: the reference, what it points to vs what exists now

### expired-date

Date references in documentation beyond the staleness threshold:

- Dates older than `date_staleness_months` from `thresholds.yml`
- "Updated on YYYY-MM-DD" headers with old dates
- Copyright years that may need updating
- Changelog entries referenced as "recent" but are old

Severity: **low** (date is old but not harmful),
**medium** (date suggests active maintenance that isn't happening)

Evidence: the date found, the threshold, how far past threshold

## Guidelines

- Focus on documentation that is **wrong** over documentation that is
  **missing** — misleading docs are worse than no docs
- Do not flag TODO/FIXME comments (handled by check-health-tech-debt)
- Do not flag sparse documentation in early-stage or prototype code
- For README analysis, compare installation commands against actual project
  files (package.json, pyproject.toml, Makefile, etc.)
- Accept that some internal code may reasonably lack documentation
- If no issues found, return zero findings — do not invent issues

## When to Use

- Loaded by the checker agent during docs-domain analysis
- Applies to: `.md`, `.rst`, `.txt`, `README*`, `CHANGELOG*`, `docs/`,
  and inline comments in source files

## When NOT to Use

- Not invoked directly — always via the checker agent
- Not for missing documentation (use check-docs-missing-api instead)
- Not for code examples in docs (use check-docs-examples instead)
