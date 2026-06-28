---
description: Test-first development patterns and framework conventions. Use when writing tests, adding coverage, or debugging test failures.
---

# Testing Patterns

## Approach

- Write tests before or alongside implementation
- Test behavior, not implementation details
- Keep tests focused and independent
- Each test should be understandable in isolation

## Structure

- Arrange-Act-Assert pattern
- One assertion concept per test
- Descriptive test names explaining the expected behavior and condition
- Group related tests logically

```text
Bad:  test_login()
Bad:  test_email_validation_works()
Good: test_login_fails_with_expired_token()
Good: test_email_rejects_missing_at_symbol()
```

### Test Organization

```text
Test Suite
├── Happy path tests
├── Edge cases (boundary values, empty/null, special characters)
├── Error cases (expected failures, specific error types)
├── Security cases (malicious input, permission boundaries)
└── Integration tests (critical paths, system boundaries)
```

## Coverage

- Test happy path, edge cases, and error conditions
- Test boundary values and empty/null inputs
- Don't test framework or library internals
- Integration tests for critical paths and system boundaries

## Security Testing

- Test validation functions with malicious inputs (injection, overflow)
- Verify error messages don't leak sensitive information
- Test access control enforcement at boundaries
- Confirm sensitive data is redacted in logs and error output

## Environment Compatibility

- Tests must produce identical results in local dev, CI, and staging
- No test dependencies on external services — mock or fixture everything
- Use parameterized tests for scenarios that vary by environment or input
- Capture log output in-memory during tests — no side effects

## When to Use

- Writing new tests or expanding coverage for existing code
- Setting up test infrastructure or fixtures
- Debugging flaky or failing tests

## When NOT to Use

- Quick spike or prototype (test after validating the approach)
- Pure documentation or configuration changes
- Throwaway scripts not intended for production

## Test Independence & Hygiene

- Tests must be deterministic — same result every run, any order
- Mock external dependencies at boundaries (APIs, databases, filesystem)
- Use the project's existing test framework and conventions
- Place test files following project directory structure
- Clean up test state after each test; never depend on execution order
- Use test data builders or factories for complex objects
