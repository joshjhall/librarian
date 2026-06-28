---
description: Implementation loop that drives the "Make it Secure" pass — hardening against injection, secrets exposure, and OWASP top 10 vulnerabilities. Activated by security and data-storage contexts. Not invoked directly.
---

# loop-make-it-secure

Drive a security hardening pass over changed files. Focus on intentional
attack prevention, not input validation (that is Make it Safe).

**Detailed checklist**: See `development-workflow/phase-details.md` Phase 4
(Make it Secure) — load it when starting this loop.

**Companion files**: See `contract.md` for the completion report format. See
`thresholds.yml` for configurable thresholds. Load both before starting.

## Workflow

1. Run `patterns.sh` on changed files to detect security issues
1. For each HIGH-certainty finding, apply the fix:
   - Replace string interpolation in queries with parameterized queries
   - Externalize hardcoded secrets to environment variables
   - Replace denylist validation with allowlist validation
   - Add output encoding appropriate to the context
   - Mask sensitive data in log statements
1. Run the test suite to confirm no regressions
1. Run `patterns.sh` again — zero HIGH findings required to exit
1. Commit atomically: `loop(make-it-secure): harden against {category}`

## Pre-Scan Categories

`patterns.sh` detects these security issues:

| Category                     | What it detects                                        |
| ---------------------------- | ------------------------------------------------------ |
| `hardcoded-secret`           | API keys, tokens, passwords in source code             |
| `string-interpolation-query` | SQL/NoSQL queries built via string concatenation       |
| `dangerous-function`         | Unsafe functions (shell injection, deserialization)    |
| `denylist-validation`        | Input validation using denylists instead of allowlists |

## Exit Criteria

The loop is complete when:

- `patterns.sh` reports zero HIGH-certainty findings on changed files
- No OWASP top 10 vulnerabilities present (LLM judgment)
- Sensitive operations have audit trails where appropriate

## What NOT to Do

- Do not implement custom cryptography
- Do not rely on client-side validation alone
- Do not add security theater (checks that look secure but are not)
- Do not over-scope — focus on files changed in this work only
