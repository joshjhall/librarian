---
description: Checks documentation structure, missing standard files, directory README coverage, and content duplication. Used by checker agent in audit and review modes.
---

# check-docs-organization

Analyze the documentation structure for completeness and consistency. You
receive pre-scan results (deterministic hits from `patterns.sh`) and a file
manifest from the checker agent.

**Companion files**: See `contract.md` for output format. See `thresholds.yml`
for configurable thresholds — load both when running analysis.

## Workflow

1. Review pre-scan results passed by the checker agent. For each:

   - **Missing root docs**: confirm the file is genuinely expected for this
     project type (e.g., LICENSE is always expected, CONTRIBUTING.md only for
     open-source)
   - **Missing dir READMEs**: confirm the directory contains meaningful content
     that warrants documentation

1. Analyze the broader documentation structure:

   - Is the README well-organized (sections in logical order)?
   - Are there orphaned docs that nothing links to?
   - Is there significant content duplication between README and docs/?
   - Does the docs/ directory have a consistent structure?

1. Emit findings following `contract.md` format

## Categories

### missing-root-doc

Standard root-level files that are missing:

- `README.md` — always expected
- `LICENSE` or `LICENSE.md` — expected for public/open-source projects
- `CHANGELOG.md` — expected for versioned projects
- `CONTRIBUTING.md` — expected for projects accepting contributions

Severity: **high** (README.md missing), **medium** (LICENSE missing for
public project), **low** (optional file missing)

Evidence: what file is missing, why it's expected for this project

### missing-dir-readme

Directories containing significant content but no README:

- Source directories with multiple files and no overview
- Directories at configurable depth that lack README.md

Severity: **medium** (directory has >5 files and no README),
**low** (directory could benefit from README)

Evidence: directory path, file count, content description

### inconsistent-structure

Documentation structure inconsistencies:

- Mix of documentation formats within the same directory
- Inconsistent heading levels across related documents
- Documentation scattered across root and docs/ without clear organization

Severity: **medium** (confusing for contributors),
**low** (minor inconsistency)

Evidence: the inconsistency, what was expected

### doc-duplication

Significant content overlap between documentation files:

- README sections that duplicate content in docs/
- Multiple files covering the same topic without cross-references
- Copy-pasted sections that may diverge over time

Severity: **medium** (high risk of divergence),
**low** (minor overlap)

Evidence: the duplicated content locations, overlap percentage

## Guidelines

- Adjust expectations based on project type (library vs application, public
  vs private, early-stage vs mature)
- Do not flag missing docs for trivial projects (\<5 source files)
- Consider the project's contribution model when assessing CONTRIBUTING.md
- If no issues found, return zero findings

## When to Use

- Loaded by the checker agent during docs-domain analysis
- Applies to: project root and documentation directories

## When NOT to Use

- Not invoked directly — always via the checker agent
- Not for content accuracy (use check-docs-staleness)
- Not for link validation (use check-docs-deadlinks)
