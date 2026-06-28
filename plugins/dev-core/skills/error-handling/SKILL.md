---
description: Error handling patterns, retry strategies, and resilience guidance. Use when implementing error handling, validation, retry logic, or graceful degradation.
---

# Error Handling

**Detailed reference**: See `patterns.md` in this skill directory for decision
tables, backoff formulas, degradation strategies, and the error accumulator
pattern. Load it when implementing error handling, retry logic, or batch
processing.

## Error Hierarchy

- Use specific error/exception types for each distinct failure condition
- Include structured context (file paths, values, operation) — not just messages
- Preserve exception chains to maintain full diagnostic context
- Never raise generic base exceptions in production code
- Make error context programmatically accessible, not just human-readable

## Validation

Validate at system boundaries — not deep in business logic.

### Layers

- **Syntactic**: Types, formats, lengths, patterns
- **Semantic**: Business rules, logical consistency, domain constraints
- **Security**: Sanitization, permissions, rate limiting

### Principles

- Fail fast with clear, actionable messages explaining what's wrong and how to fix
- Never trust external input (user input, APIs, files, environment variables)
- Use type systems to make invalid states unrepresentable
- Preserve original input in validation errors for debugging

## Retry Strategies

### When to Retry

- Network timeouts and connection errors
- Rate limit responses
- Temporary service unavailability

### When NOT to Retry

- Authentication failures
- Validation errors
- Configuration errors
- Business logic violations

### How to Retry

- Exponential backoff with jitter to prevent thundering herds
- Set reasonable max attempts (3–5 typical)
- Cap maximum delay to prevent infinite waits
- Log each attempt with context, wait time, and attempt number
- Support cancellation for user-facing operations

## Graceful Degradation

- Core functionality must work even when optional dependencies are unavailable
- Detect capabilities at runtime, not at initialization
- Always warn users when operating in degraded mode — never fail silently
- Provide actionable messages (what's missing, how to install/fix)
- Test degraded modes explicitly

## Partial Failure Handling

For batch/bulk operations where some success is better than none:

- Accumulate errors without stopping the entire operation
- Continue processing after individual item failures
- Return both successes and failures to the caller
- Distinguish complete failure from partial success
- Provide clear summaries of what worked and what didn't

### When NOT to Use

- Database transactions requiring atomicity
- Configuration validation (all must be valid)
- Operations where one failure invalidates others

## When to Use

- Adding error handling, validation, or input checking
- Implementing retry logic or resilience patterns
- Processing batches where partial failure is acceptable

## When NOT to Use

- Pure refactoring that doesn't change error behavior
- UI/presentation logic with no external calls
- Prototyping where error handling is deferred

## Anti-Patterns

- Catching generic exceptions and swallowing them silently
- Error messages with no context ("Something went wrong")
- Retrying permanent failures (auth errors, validation errors)
- Double-logging (if exceptions auto-log, don't log again at raise site)
- String-parsing error messages instead of using typed error properties
