# Issue Templates — Agent-Parseable Format

Reference companion for `SKILL.md`. Load when creating or updating issues.
Each template uses H2 headers that agents can reliably parse.

---

## Title Conventions

Titles should be concise, specific, and action-oriented:

**Good — specific, actionable:**

```markdown
Set core.sshCommand globally so VS Code git GUI works with provisioned SSH keys
Add pagination to /api/users endpoint
Fix race condition in session token refresh
```

**Bad — vague, no action:**

```markdown
SSH key issue
API improvement
Fix bug
```

Keep under 70 characters. Use the description for details.

---

## Base Template

All issues use this structure. Type-specific sections are inserted after
"Proposed Solution."

```markdown
## Summary

{1-3 sentences: what needs to change and why}

## Problem

{Current behavior or gap. For bugs: what happens. For features: what's missing.
For refactors: what's wrong with current structure.}

## Proposed Solution

{Expected approach. Be specific enough that an agent can plan implementation
without further clarification.}

{TYPE-SPECIFIC SECTIONS — see below}

## Acceptance Criteria

- [ ] {Concrete, testable criterion}
- [ ] {Another criterion}
- [ ] {Each checkbox = one verifiable behavior or state}

## Affected Files

- `path/to/file1.ext` — {what changes}
- `path/to/file2.ext` — {what changes}
- `path/to/directory/` — {scope of changes}

## Context

{Background: what prompted this, related discussions, constraints.
Link related issues with #N format.}
```

---

## Type-Specific Sections

Insert these after "Proposed Solution" when applicable.

### Bug (`type/bug`)

```markdown
## Steps to Reproduce

1. {Step 1}
2. {Step 2}
3. {Observe: description of incorrect behavior}

## Expected Behavior

{What should happen instead}
```

### Feature (`type/feature`)

```markdown
## User Story

As a {role}, I want {capability} so that {benefit}.
```

### Refactor (`type/refactor`)

```markdown
## Current State

{What the code looks like now and why it's problematic}

## Target State

{What the code should look like after the refactor}
```

---

## Scope Indicators

Include these in the Summary or Affected Files to help effort estimation:

- **File count**: "Affects 3 files in `src/payments/`"
- **Module count**: "Touches auth and session modules"
- **Cross-cutting**: "Requires changes across API, DB, and test layers"

When an issue lists 9+ files or 4+ directories, add a scope warning:

```markdown
> **Scope note**: This issue touches {N} files across {M} directories.
> Consider splitting into smaller issues if independent sub-tasks exist.
```

---

## Evaluation-Sourced Template

For issues originating from evaluation reports (e.g., agentsys evaluation,
issue #304). Insert these sections after "Proposed Solution":

```markdown
## Evaluation Source

- **Report**: {path to evaluation document or issue number}
- **Section**: {specific section or recommendation ID, e.g., "R4: Parallelize code-reviewer"}
- **Disposition**: {Adopt | Adapt | Build | Skip}

## Current State

{What our system does now in the area this recommendation addresses}

## Target State

{What the system should do after implementing this recommendation}
```

Use when: the issue directly implements a recommendation from an evaluation
or benchmarking exercise. The Evaluation Source section creates traceability
from issue back to the analysis that motivated it.

---

## Foundational Dependency Template

For issues that block multiple follow-up issues. Insert these sections after
"Acceptance Criteria":

```markdown
## Blocked Issues

This issue is **foundational** — the following issues depend on its
deliverables:

- #{N1} — {title} (depends on: {specific deliverable})
- #{N2} — {title} (depends on: {specific deliverable})

## Deliverables

Concrete outputs that downstream issues depend on:

- [ ] {Deliverable 1 — what it is and where it lives}
- [ ] {Deliverable 2}
```

Use when: an issue's completion is a prerequisite for 2+ other issues.
The Blocked Issues section makes the dependency graph explicit so agents
can prioritize correctly.

---

## Agent Parsing Notes

Agents consuming these issues (e.g., `/next-issue` Phase 2) can rely on:

- **Summary** is always the first H2 — read for quick context
- **Acceptance Criteria** uses `- [ ]` checkbox format — count for done signal
- **Affected Files** uses backtick-wrapped paths — extract with regex
  `` `([^`]+)` ``
- **Context** contains `#N` issue references — extract related issues
- H2 headers are stable anchors: `## Summary`, `## Problem`,
  `## Proposed Solution`, `## Acceptance Criteria`, `## Affected Files`
- **Evaluation Source** uses `**Report**:`, `**Section**:`, `**Disposition**:`
  markers — extract evaluation traceability
- **Blocked Issues** uses `- #N` references — extract dependency graph
- **Deliverables** uses `- [ ]` checkbox format — track foundational outputs
