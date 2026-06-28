---
description: Code quality standards, naming conventions, and review checklist. Use when writing or reviewing code for style, naming, logging, or review readiness.
---

# Code Quality

## Principles

- Prefer simple, readable code over clever code
- Follow existing codebase conventions
- Don't add unnecessary abstractions or over-engineer
- Only make changes that are directly requested or clearly necessary

## Naming

- Consistency over brevity — choose clarity over character count
- State checks: `is_`, `has_`, `can_` prefixes (return boolean)
- Actions: imperative verbs (`create`, `validate`, `send`)
- Enforcement: `require_` prefix (raises on failure)
- Follow the project's existing naming patterns exactly

## Logging

- Log events as structured data, not formatted strings
- Never log passwords, tokens, API keys, or PII
- Use appropriate severity: errors for failures, info for operations, debug for details
- Include context fields (request ID, user, operation) — don't concatenate into messages

```text
Bad:  log(f"User {user_id} failed to process order {order_id}: {err}")
Good: log.error("order_processing_failed", user_id=user_id, order_id=order_id, error=err)
```

## Review Checklist

- No security vulnerabilities (injection, XSS, credential exposure)
- Error handling at system boundaries (user input, external APIs)
- Errors use specific types with structured context, not generic exceptions
- No hardcoded secrets or credentials
- Consistent naming conventions matching the project
- No dead code or unused imports
- No backwards-compatibility hacks for removed code
- Resource cleanup on all exit paths (connections, file handles, temp files)

## When to Use

- Writing new code or modifying existing code
- Reviewing code before commit or PR
- Naming functions, variables, or modules

## When NOT to Use

- Spike or throwaway prototyping (clean up later)
- Emergency hotfixes (follow up with quality pass)

## Avoid

- Adding features, refactoring, or "improvements" beyond what was asked
- Adding docstrings, comments, or type annotations to unchanged code
- Adding error handling for scenarios that can't happen
- Creating helpers or abstractions for one-time operations
- Designing for hypothetical future requirements
- Fat interfaces with optional methods that do nothing or raise NotImplementedError
