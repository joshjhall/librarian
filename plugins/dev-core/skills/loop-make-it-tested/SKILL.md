---
description: Implementation loop that drives the "Make it Tested" pass — comprehensive test coverage for changed code with behavior-focused assertions. Activated by contexts or always run as a core pipeline step. Not invoked directly.
---

# loop-make-it-tested

Drive a testing pass: ensure changed code has comprehensive test coverage
with behavior-focused assertions.

**Detailed checklist**: See `development-workflow/phase-details.md` Phase 8
(Make it Tested) — load it when starting this loop.

**Companion files**: See `contract.md` for the completion report format. See
`thresholds.yml` for configurable thresholds. Load both before starting.

## Workflow

1. Detect the project's test runner from config files:
   - `package.json` (jest/vitest/mocha) | `pyproject.toml`/`setup.cfg` (pytest)
   - `go.mod` (go test) | `Cargo.toml` (cargo test) | `Makefile`
1. Run `patterns.sh` on changed files to find untested public APIs
1. Write tests following Arrange-Act-Assert:
   - Happy path with end-to-end assertions
   - Edge cases from the implementation (empty, null, boundary values)
   - Error conditions (correct error types and messages)
   - Security cases if the security context is active
1. Run the test suite to confirm all tests pass
1. Run `patterns.sh` again to verify coverage gaps are filled
1. Commit atomically: `loop(make-it-tested): add tests for {scope}`

## Pre-Scan Categories

`patterns.sh` detects these coverage gaps:

| Category              | What it detects                                 |
| --------------------- | ----------------------------------------------- |
| `untested-public-api` | Exported functions/classes with no test file    |
| `test-no-assertions`  | Test functions without assertion statements     |
| `missing-test-file`   | Source module with no corresponding test module |

## Exit Criteria

The loop is complete when:

- `patterns.sh` reports zero HIGH-certainty gaps for changed files
- All tests pass deterministically
- Happy path, edge cases, and error conditions are covered (LLM judgment)

## Context-Sensitive Testing

When activated by a context, the testing focus shifts:

- **security context**: Include injection attempts, auth boundary tests
- **data-storage context**: Include connection failure, timeout, constraint
  violation tests
- **Default** (no context): Standard behavior testing

## What NOT to Do

- Do not test framework or library internals
- Do not write tests that depend on execution order
- Do not test implementation details — test behavior
- Do not leave flaky tests — fix or remove them
