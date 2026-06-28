---
description: Implementation loop that drives the "Make it Documented" pass — public API documentation, design decision comments, and README updates for changed code. Activated by contexts or always run as a core pipeline step. Not invoked directly.
---

# loop-make-it-documented

Drive a documentation pass: ensure changed code has proper public API docs,
non-obvious design decisions are explained, and user-facing docs are updated.

**Detailed checklist**: See `development-workflow/phase-details.md` Phase 9
(Make it Documented) — load it when starting this loop.

**Companion files**: See `contract.md` for the completion report format. See
`thresholds.yml` for configurable thresholds. Load both before starting.

## Workflow

1. Run `patterns.sh` on changed files to find undocumented public APIs
1. Add documentation where needed:
   - Public function/class docstrings (parameters, return values, examples)
   - Non-obvious design decision comments ("why", not "what")
   - README or user-facing doc updates if behavior changed
   - Configuration options documented with defaults
   - Breaking changes documented with migration instructions
1. Run `patterns.sh` again to verify gaps are filled
1. Commit atomically: `loop(make-it-documented): document {scope}`

## Pre-Scan Categories

`patterns.sh` detects these documentation gaps:

| Category                       | What it detects                         |
| ------------------------------ | --------------------------------------- |
| `undocumented-public-function` | Public functions without docstrings     |
| `undocumented-public-class`    | Public classes without class-level docs |
| `undocumented-export`          | Exported symbols without JSDoc/GoDoc    |

## Exit Criteria

The loop is complete when:

- `patterns.sh` reports zero HIGH-certainty gaps for changed files
- Public APIs have complete documentation (LLM judgment)
- Non-obvious design decisions are explained

## Context-Sensitive Documentation

When activated by a context, documentation focus shifts:

- **security context**: Document security decisions, auth flows, trust boundaries
- **data-storage context**: Document schema decisions, migration steps, query patterns
- **Default** (no context): Standard API documentation

## What NOT to Do

- Do not document obvious code ("increment counter by 1")
- Do not add docstrings to every private function
- Do not write documentation that duplicates the code
- Do not leave TODOs in documentation — do it or create a ticket
- Do not over-document test files
