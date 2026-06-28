---
description: Implementation loop that drives the "Make it Right" pass — refactoring for clarity, conventions, and architecture without changing behavior. Used by the pipeline orchestrator during implementation phase. Not invoked directly.
---

# loop-make-it-right

Drive the second implementation pass: refactor for clarity and project
conventions without changing behavior.

**Detailed checklist**: See `development-workflow/phase-details.md` Phase 2
(Make it Right) — load it when starting this loop.

**Companion files**: See `contract.md` for the completion report format. See
`thresholds.yml` for configurable thresholds. Load both before starting.

## Workflow

1. Run `patterns.sh` on changed files to identify structural issues
1. Refactor without changing behavior:
   - Rename unclear variables and functions
   - Break large functions into smaller focused ones
   - Extract duplicated code (3+ repetitions threshold)
   - Apply existing project patterns and conventions
   - Add type hints / interfaces where expected
1. Run the test suite to confirm all tests still pass
1. Run `patterns.sh` again to verify issues are resolved
1. Commit atomically: `loop(make-it-right): {description}`

## Pre-Scan Categories

`patterns.sh` detects these structural issues:

| Category           | What it detects                               |
| ------------------ | --------------------------------------------- |
| `long-function`    | Functions exceeding the line count threshold  |
| `deep-nesting`     | Code with nesting depth beyond threshold      |
| `single-char-name` | Single-character variable names outside loops |

## Exit Criteria

The loop is complete when:

- `patterns.sh` reports zero HIGH-certainty issues on changed files
- All pre-existing tests still pass without modification
- Code follows project conventions (LLM judgment)

## What NOT to Do

- Do not change behavior — only restructure
- Do not add new features or handle edge cases
- Do not extract abstractions for code used only once or twice
- Do not add error handling beyond what exists
- Do not add tests — that is loop-make-it-tested
