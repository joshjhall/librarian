---
description: Implementation loop that drives the "Make it Work" pass — real end-to-end functionality on the happy path. Used by the pipeline orchestrator during implementation phase. Not invoked directly.
---

# loop-make-it-work

Drive the first implementation pass: get the feature working end-to-end on the
happy path with real operations, no stubs.

**Detailed checklist**: See `development-workflow/phase-details.md` Phase 1
(Make it Work) — load it when starting this loop.

**Companion files**: See `contract.md` for the completion report format. See
`thresholds.yml` for configurable blocker thresholds. Load both before
starting.

## Workflow

1. Read the plan from the pipeline orchestrator's context
1. Run `patterns.sh` on changed files to detect existing blockers
1. Implement the core feature end-to-end:
   - Start with the simplest working implementation
   - Use real operations (actual DB queries, real API calls, real file I/O)
   - Focus on one vertical slice first
   - Write at least one test proving core behavior
1. Run `patterns.sh` again to verify blockers are resolved
1. Run the project's test suite to confirm the test passes
1. Commit atomically: `loop(make-it-work): {description}`

## Pre-Scan Categories

`patterns.sh` detects these blockers in changed files:

| Category        | What it detects                                      |
| --------------- | ---------------------------------------------------- |
| `stub-detected` | TODO, FIXME, STUB, PLACEHOLDER, NotImplementedError  |
| `empty-body`    | Functions/methods with empty or pass-only bodies     |
| `no-assertions` | Test files with zero assert/expect/should statements |

## Exit Criteria

The loop is complete when:

- `patterns.sh` reports zero HIGH-certainty blockers on changed files
- At least one test passes proving core behavior
- The feature works end-to-end on the happy path (LLM judgment)

## What NOT to Do

- Do not refactor while building — that is loop-make-it-right
- Do not handle edge cases — that comes in later loops
- Do not optimize — correctness first
- Do not write comprehensive tests — one proving test is enough
- Do not use mocks or stubs as substitutes for real implementation
