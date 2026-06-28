---
description: Validates code examples in documentation against actual source code. Detects broken imports, deprecated APIs, and incomplete examples. Used by checker agent.
---

# check-docs-examples

Analyze code examples in documentation files for correctness. You receive
pre-scan results (deterministic hits from `patterns.sh`) and file contents
from the checker agent.

**Companion files**: See `contract.md` for output format. See `thresholds.yml`
for configurable thresholds — load both when running analysis.

## Workflow

1. Review pre-scan results passed by the checker agent. For each:

   - **Broken imports**: verify if the imported module/file exists in the
     current project structure
   - **Missing function references**: check if the called function exists
     and has the expected signature

1. Analyze code examples the pre-scan missed:

   - Do examples use deprecated or removed APIs?
   - Are examples missing required setup steps or context?
   - Would copy-pasting the example actually work?
   - Do examples match current function signatures?

1. Emit findings following `contract.md` format

## Categories

### broken-example

Code examples that would produce errors if executed:

- Examples with import statements for modules that don't exist
- Function calls with wrong number of arguments
- Examples referencing classes or methods that have been removed
- Shell commands that reference non-existent scripts or tools

Severity: **high** (example would error on execution),
**medium** (example would produce unexpected results)

Evidence: the example code, what's wrong, what the correct version would be

### deprecated-example

Examples using deprecated APIs or patterns:

- Function calls to deprecated methods (where a replacement exists)
- Examples using old API versions when newer ones are available
- Import paths that have been reorganized

Severity: **medium** (uses deprecated API but still works),
**low** (uses older pattern but functionally equivalent)

Evidence: the deprecated usage, the current recommended alternative

### incomplete-example

Examples missing essential context for execution:

- Missing required imports or setup steps
- Missing configuration or environment prerequisites
- Partial examples that can't stand alone
- Examples that reference variables defined elsewhere without mention

Severity: **medium** (example misleading without context),
**low** (example is a snippet, reader expected to have context)

Evidence: what's missing, what would make the example complete

## Guidelines

- Verify imports against actual project source, not just common libraries
- For shell/CLI examples, check if referenced scripts and tools exist
- Do not flag intentionally abbreviated examples (marked with `...` or
  comments like "// ...")
- Do not flag examples in internal design docs (they may be aspirational)
- Compare against actual function signatures when verifiable
- If no issues found, return zero findings

## When to Use

- Loaded by the checker agent during docs-domain analysis
- Applies to: fenced code blocks in `.md`, `.rst` files

## When NOT to Use

- Not invoked directly — always via the checker agent
- Not for documentation staleness (use check-docs-staleness)
- Not for API documentation coverage (use check-docs-missing-api)
