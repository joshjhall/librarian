# Error Handling — Pattern Details

Reference companion for `SKILL.md`. Load this when implementing error handling,
retry logic, degradation strategies, or batch processing for detailed guidance,
decision criteria, and examples.

---

## Error Hierarchy

### Design Principles

1. **Specificity over generality**: Use the most specific error type available.
   Create new types for distinct error conditions rather than reusing generic ones.

1. **Context over messages**: Every error should include structured context that
   is programmatically accessible — not just a human-readable string.

1. **Preserve exception chains**: Always link to the original cause so the full
   diagnostic trail is available. Never swallow the original error.

1. **Domain alignment**: Error hierarchies should mirror the system architecture.
   Each major component has its own error subtree.

### Good Error Pattern

```text
Error includes:
- Specific type (FileParsingError, not GenericError)
- Structured context (file_path, line_number, expected_format)
- Original cause (chained from the underlying exception)
- Auto-logging (no manual log statement needed at the raise site)
```

### Anti-Patterns

| Pattern                     | Problem                                        | Fix                             |
| --------------------------- | ---------------------------------------------- | ------------------------------- |
| Generic base exception      | Can't distinguish error types programmatically | Create specific exception types |
| Message-only context        | Can't extract fields for monitoring/alerting   | Add structured properties       |
| Broken chain                | Lose root cause information                    | Always chain with `from`        |
| Double logging              | Same error logged twice (manual + auto)        | Let the exception framework log |
| String formatting in errors | Fragile, not searchable                        | Use structured context fields   |

---

## Validation — Detailed Guidance

### Layer Architecture

Validation happens at three layers, applied at system boundaries:

**Layer 1: Syntactic validation** — is the data well-formed?

- Correct data types (string, int, list)
- Format constraints (email format, date format, UUID format)
- Length limits (min/max string length, array size)
- Pattern matching (regex for phone numbers, postal codes)

**Layer 2: Semantic validation** — does the data make sense?

- Business rules (end date must be after start date)
- Logical consistency (discount can't exceed 100%)
- Domain constraints (age must be positive)
- Relationship integrity (referenced ID must exist)

**Layer 3: Security validation** — is the data safe?

- Input sanitization (strip control characters, normalize unicode)
- Permission checks (user authorized for this operation)
- Rate limiting (too many requests from this source)
- Threat detection (SQL injection patterns, XSS payloads)

### Where to Validate

| Boundary               | What to validate                    | Example                          |
| ---------------------- | ----------------------------------- | -------------------------------- |
| API endpoints          | All request parameters and body     | REST handler, GraphQL resolver   |
| CLI entry points       | All arguments and options           | Command handler, argument parser |
| File ingestion         | File format, size, content type     | CSV parser, config loader        |
| External API responses | Status codes, expected schema       | HTTP client, SDK wrapper         |
| Environment variables  | Required vars present, valid format | Startup config loader            |
| Database reads         | Data integrity after retrieval      | Post-query validation            |

### Error Message Quality

Good validation errors explain what's wrong AND how to fix it:

```text
Bad:  "Invalid input"
Bad:  "Validation failed"
Good: "Pattern name must be at least 3 characters, got 1: 'x'"
Good: "Quality score must be between 1 and 5, got 7"
Good: "File not found: /path/to/file.txt — check the path and ensure the file exists"
```

---

## Retry Strategies — Detailed Guidance

### Decision Framework

**Always retry** (transient failures):

- Network timeouts
- Connection refused / reset
- DNS resolution failures
- HTTP 429 (rate limited) — respect Retry-After header
- HTTP 502, 503, 504 (temporary server issues)

**Never retry** (permanent failures):

- HTTP 400 (bad request) — input won't improve on retry
- HTTP 401, 403 (auth/permission) — credentials won't change
- Validation errors — same input will fail again
- Configuration errors — environment won't change
- Business logic violations — retry won't help

**Conditional retry** (depends on context):

- HTTP 500 — may be transient or permanent
- Disk full errors — may resolve if something else cleans up
- Lock contention — may resolve when lock is released

### Backoff Configuration

```text
Exponential backoff with jitter:

  delay = min(max_delay, base_delay * (2 ^ attempt)) + random_jitter

Typical configuration:
  base_delay:   1 second
  max_delay:    30 seconds
  max_attempts: 3-5
  jitter:       0 to 1 second (random)

Example progression:
  Attempt 1: ~1s  delay
  Attempt 2: ~2s  delay
  Attempt 3: ~4s  delay
  Attempt 4: ~8s  delay
  Attempt 5: ~16s delay (or max_delay)
```

### Why Jitter Matters

Without jitter, if 100 clients all fail at the same time, they all retry at
the same time too — creating a "thundering herd" that can take down the service
again. Random jitter spreads retries across time.

### Logging Retries

Each retry attempt should log:

- Operation being retried
- Attempt number (e.g., "attempt 3 of 5")
- Wait time before next attempt
- Error that triggered the retry
- Final failure should log all attempts as context

---

## Graceful Degradation — Detailed Guidance

### Core Pattern

The system should function with reduced capabilities when optional dependencies
are unavailable. The key distinction: **mandatory vs. optional**.

| Dependency type | On failure            | Example                                          |
| --------------- | --------------------- | ------------------------------------------------ |
| Mandatory       | Fail with clear error | Database connection for a data app               |
| Optional        | Warn and continue     | Caching layer, analytics, GPU acceleration       |
| Enhancement     | Silent fallback       | Syntax highlighting, progress bars, color output |

### Implementation Strategies

**1. Try-Optimal-Then-Fallback**
Attempt the best solution first. If it fails, fall back to a less capable
but still functional alternative. Always warn the user.

**2. Feature Detection at Runtime**
Check if optional capabilities are available when they're needed — not at
import time or initialization. This prevents startup failures from optional
dependencies.

**3. Progressive Enhancement**
Core functionality is always available. Enhanced features layer on top if
their dependencies are present. Each enhancement is independent.

**4. Capability-Based Routing**
Route requests to the best available implementation. If the preferred
provider is down, use the next best option.

### Warning Quality

When operating in degraded mode, warnings should include:

- What's unavailable and why
- What capability is reduced
- How to install/fix the missing dependency
- Whether the workaround is transparent or lossy

```text
Bad:  "Feature unavailable"
Good: "GPU acceleration not available — operations will be slower.
       To enable: pip install package[gpu]"
```

### Testing Degraded Modes

Explicitly test that the system works without each optional dependency:

- Mock or remove the optional dependency
- Verify core functionality still works
- Verify warnings are produced (not silent)
- Verify no exceptions propagate to the user

---

## Partial Failure Handling — Detailed Guidance

### When to Use

Use partial failure handling when processing a collection of independent items
where some failures shouldn't stop the entire operation:

| Scenario                       | Use partial failure? | Why                                         |
| ------------------------------ | -------------------- | ------------------------------------------- |
| Analyzing files in a directory | Yes                  | One bad file shouldn't block the rest       |
| Bulk API calls                 | Yes                  | Process what succeeds, report what fails    |
| Sending notifications          | Yes                  | One bad email shouldn't block others        |
| Pattern extraction             | Yes                  | Some patterns extracted is better than none |
| Database transaction           | **No**               | Atomicity required — all or nothing         |
| Config validation              | **No**               | Partial config is worse than no config      |
| Dependent operations           | **No**               | Later steps depend on earlier success       |
| Financial transfers            | **No**               | Partial transfer would be inconsistent      |

### Error Accumulator Pattern

The core pattern for partial failure handling:

1. Create an accumulator to collect errors
1. Process each item in a loop
1. On success: add result to successes list
1. On failure: add error to accumulator, continue processing
1. After the loop, evaluate the outcome:
   - All succeeded → return results
   - Some succeeded → return results + error summary (partial success)
   - None succeeded → raise error with all failure details (complete failure)

### Distinguishing Outcomes

The caller needs to know which of three outcomes occurred:

**Complete success**: All items processed. Return results normally.

**Partial success**: Some items processed. Return results AND failures.
The caller decides whether partial results are acceptable.

**Complete failure**: Nothing processed. Raise an error with all failure
details so the caller can diagnose the issue.

### Reporting to Users

For CLI/UI contexts, partial failures should report:

- Total items attempted
- How many succeeded (with details if useful)
- How many failed (with per-item error reasons)
- Overall exit code should indicate failure if any items failed

---

## Error Recovery Escalation

When encountering errors during development, follow this escalation:

### 0-5 minutes: Read and understand

- Read the full error message carefully
- Note file paths, line numbers, error types
- Check for common patterns (typos, missing imports, wrong paths)

### 5-10 minutes: Try simple fixes

- Path issues: verify with `ls`, check working directory
- Environment issues: verify tool installation, check PATH
- Permission issues: check file permissions
- Dependency issues: verify installation

### 10-15 minutes: Try manual equivalent

- Break the automated step into manual sub-steps
- Run each sub-step individually to isolate the failure
- Check intermediate results

### After 15 minutes: Escalate

- Document what you've tried and what happened
- Create a blocker with reproduction steps
- Move to other work while waiting for resolution

### Always document

- Error encountered (tool, message, context)
- Attempts made and their results
- Solution that worked
- Prevention strategy for the future
