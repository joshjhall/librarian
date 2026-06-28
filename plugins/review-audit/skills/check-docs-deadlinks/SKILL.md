---
description: Validates internal and external links in documentation files. Detects broken relative links, missing anchors, and suspicious external URLs. Used by checker agent.
---

# check-docs-deadlinks

Analyze documentation files for broken or suspicious links. You receive
pre-scan results (deterministic hits from `patterns.sh`) and file contents
from the checker agent.

**Companion files**: See `contract.md` for output format. See `thresholds.yml`
for configurable thresholds — load both when running analysis.

## Workflow

1. Review pre-scan results passed by the checker agent. For each:

   - **Broken relative links** (file doesn't exist): confirm by checking path
     resolution from the document's directory
   - **Broken anchors** (heading doesn't exist in target): confirm by reading
     the target file and checking headings
   - **Suspicious external URLs**: assess if the URL pattern indicates a
     deprecated or moved resource

1. Analyze files not covered by pre-scan for additional link issues:

   - Links to renamed files (common after refactoring)
   - Anchors that reference old heading text
   - Relative links with incorrect depth (`../` too many or too few)

1. Emit findings following `contract.md` format

## Categories

### broken-relative-link

Internal links pointing to files that don't exist:

- `[text](path/to/file.md)` where file.md is missing
- Image references `![alt](path/to/image.png)` where image is missing
- Links using wrong path depth after directory restructuring

Severity: **high** (link in README or setup docs), **medium** (link in
internal docs)

Evidence: the link, resolved path, what exists nearby

### broken-anchor

Links to specific headings that don't exist in the target:

- `[text](file.md#heading)` where heading doesn't match any heading in file.md
- `[text](#heading)` within the same file where heading is missing
- Anchors broken by heading rename

Severity: **medium** (anchor doesn't resolve),
**low** (anchor is close match to an existing heading)

Evidence: the anchor, target file headings, closest match

### suspicious-external-link

External URLs that may be dead or deprecated:

- URLs containing deprecation/sunset indicators in path
- Links to known-deprecated API versions
- URLs with patterns suggesting moved resources

Severity: **medium** (URL likely dead), **low** (URL may be outdated)

Evidence: the URL, why it's suspicious

Note: This skill does NOT perform HTTP requests to validate external URLs.
It uses URL pattern analysis only. The pre-scan detects common dead-link
patterns; the LLM assesses remaining URLs by pattern.

## Guidelines

- Resolve relative links from the document's directory, not the project root
- Account for GitHub/GitLab auto-generated heading anchors (lowercase,
  hyphens replacing spaces, special chars stripped)
- Do not flag anchor links in auto-generated documentation
- External URL validation is pattern-based only — no network requests
- If no issues found, return zero findings

## When to Use

- Loaded by the checker agent during docs-domain analysis
- Applies to: `.md`, `.rst`, `.txt`, `README*`, `docs/`

## When NOT to Use

- Not invoked directly — always via the checker agent
- Not for stale content (use check-docs-staleness)
- Not for code examples (use check-docs-examples)
