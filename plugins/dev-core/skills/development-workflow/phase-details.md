# Development Workflow — Phase Details

Reference companion for `SKILL.md`. Load this when starting a new development
task or transitioning between phases for detailed guidance on each phase's goals,
checklist, common mistakes, and "done" criteria.

---

## Phase 1: Make it Work

**Goal**: Real end-to-end functionality on the happy path. Not stubs, not mocks,
not TODOs — actual working code with real operations.

**Time budget**: ~30% of total task time.

### Checklist

- [ ] Core feature works end-to-end on the happy path
- [ ] Real operations (actual DB queries, real API calls, real file I/O)
- [ ] At least one simple test proving core behavior works
- [ ] No stubs, TODOs, or placeholder implementations

### What TO Do

- Start with the simplest possible working implementation
- Use hardcoded values or copy-paste if it gets you working faster
- Focus on one vertical slice (e.g., Create before Read/Update/Delete)
- Write one test that proves the core behavior works

### What NOT to Do

- Don't refactor while building — that's Phase 2
- Don't handle edge cases yet — that's Phase 3
- Don't optimize — that's Phase 6
- Don't write comprehensive tests — that's Phase 8
- Don't use mocks or stubs as substitutes for real implementation

### Done When

- You can demonstrate the feature working end-to-end
- At least one test passes proving core behavior

---

## Phase 2: Make it Right

**Goal**: Refactor for clarity without changing behavior. The code should be
readable and follow project conventions.

**Time budget**: ~15% of total task time.

### Checklist

- [ ] Functions and variables have clear, descriptive names
- [ ] Functions are small and focused (one responsibility each)
- [ ] Nesting depth reduced (max 2-3 levels)
- [ ] Duplicated logic extracted (3+ instances threshold)
- [ ] Project conventions and design patterns applied
- [ ] Proper types and interfaces added
- [ ] Phase 1 tests still pass

### What TO Do

- Rename unclear variables and functions
- Break large functions into smaller, focused ones
- Extract duplicated code into shared functions (3+ repetitions)
- Apply existing project patterns and conventions
- Add type hints / interfaces where the project expects them

### What NOT to Do

- Don't change behavior — only restructure
- Don't add new features or handle edge cases yet
- Don't extract abstractions for code used only once or twice
- Don't add error handling beyond what already exists

### Done When

- Code reads clearly and follows project conventions
- All Phase 1 tests still pass without modification
- No function exceeds ~30 lines (guideline, not hard rule)

---

## Phase 3: Make it Safe

**Goal**: Handle all the ways inputs can be wrong, unexpected, or malformed.
Add error handling and resource cleanup.

**Time budget**: ~10% of total task time.

### Checklist

- [ ] All inputs validated at system boundaries
- [ ] Null/empty/negative/oversized values handled
- [ ] Error handling with specific exception types and context
- [ ] Resource cleanup on all exit paths (connections, files, temp data)
- [ ] Unicode and encoding edge cases considered
- [ ] Concurrency edge cases considered (if applicable)

### Common Edge Cases to Consider

- Empty strings, empty lists, None/null values
- Negative numbers, zero, maximum values
- Unicode characters, mixed encodings
- Very large inputs (memory/performance implications)
- Concurrent access (race conditions, deadlocks)
- File not found, permission denied, disk full
- Network timeout, connection refused

### What NOT to Do

- Don't handle errors that can't happen in your context
- Don't add validation deep inside business logic (validate at boundaries)
- Don't catch generic exceptions — use specific types

### Done When

- Bad inputs produce clear, helpful error messages
- Resources are cleaned up even when errors occur
- No unhandled exception can crash the system from user input

---

## Phase 4: Make it Secure

**Goal**: Harden against intentional attacks. Think like an attacker — what could
be exploited?

**Time budget**: ~10% of total task time.

### Checklist

- [ ] Validate against allowlists, not denylists
- [ ] Parameterized queries for all database operations
- [ ] Context-appropriate output encoding (HTML, SQL, shell, etc.)
- [ ] No internal error details exposed to users
- [ ] Sensitive data masked in logs (tokens, passwords, PII)
- [ ] Audit logging for sensitive operations
- [ ] Authentication and authorization checks on all protected paths

### OWASP Considerations

- **Injection**: Use parameterized queries, escape shell arguments
- **Broken Auth**: Verify session management, token expiration
- **Sensitive Data**: Encrypt at rest and in transit, mask in logs
- **XXE**: Disable external entity processing in XML parsers
- **Access Control**: Check permissions on every request, not just UI
- **Misconfiguration**: No default credentials, unnecessary features disabled
- **XSS**: Encode output for the correct context (HTML, JS, URL)
- **Deserialization**: Validate and sanitize before deserializing
- **Components**: Check dependencies for known vulnerabilities
- **Logging**: Log security events, don't log sensitive data

### What NOT to Do

- Don't implement custom cryptography
- Don't rely on client-side validation alone
- Don't store secrets in code or config files
- Don't use denylists for input validation (use allowlists)

### Done When

- No OWASP top 10 vulnerabilities present
- Sensitive operations have audit trails
- Error messages reveal no internal details to users

---

## Phase 5: Make it Compliant (when applicable)

**Goal**: Ensure the feature meets relevant regulatory requirements. Skip this
phase entirely if the project has no compliance requirements.

**Time budget**: ~10% of total task time (when applicable).

### When This Phase Applies

- The project handles personal data (GDPR), health data (HIPAA),
  security auditing (SOC2), or payment data (PCI-DSS)

### Checklist

- [ ] Identify which regulations apply to this feature
- [ ] Audit logging for all data access operations
- [ ] Data classification applied to sensitive fields
- [ ] PII/PHI encrypted at rest and in transit
- [ ] Data retention and deletion policies implemented
- [ ] Consent tracking where required (GDPR)

### Done When

- All data access is audit-logged and PII/PHI is encrypted
- Data can be exported/deleted per applicable regulations

---

## Phase 6: Make it Fast (only when needed)

**Goal**: Optimize actual bottlenecks identified through profiling. Never
optimize without measuring first.

**Time budget**: ~5% of total task time (only when needed).

### When This Phase Applies

- Measured performance doesn't meet requirements
- Profiling shows clear bottlenecks
- Users report slow operations
- Skip entirely if performance is acceptable

### Checklist

- [ ] Profile to identify actual bottlenecks (don't guess)
- [ ] Fix N+1 query patterns
- [ ] Eliminate unnecessary memory allocations in hot paths
- [ ] Add missing database indexes
- [ ] Add caching with clear invalidation rules
- [ ] Batch I/O operations where possible
- [ ] Document performance characteristics

### Optimization Patterns

- **N+1 queries**: Batch-load related data in one query
- **Missing indexes**: Add indexes for frequent query patterns
- **Unnecessary allocations**: Reuse objects in tight loops
- **Caching**: Add cache with TTL and explicit invalidation
- **Batch I/O**: Combine multiple small operations into one
- **Lazy loading**: Defer expensive computation until needed
- **Connection pooling**: Reuse database/HTTP connections

### What NOT to Do

- Don't optimize without profiling first
- Don't add caching without clear invalidation rules
- Don't sacrifice readability for marginal gains
- Don't optimize code that runs once at startup

### Done When

- Measured performance meets requirements
- No known N+1 queries or missing indexes
- Cache invalidation rules are documented

---

## Phase 7: Make it Observable (when applicable)

**Goal**: Add structured logging, metrics, and health checks so the system can
be monitored and debugged in production. Skip for CLI tools, scripts, or
pure libraries.

**Time budget**: ~5% of total task time (when applicable).

### Checklist

- [ ] Structured logging with consistent severity levels
- [ ] Correlation IDs for tracing requests across components
- [ ] Entry/exit logs for key operations (with timing)
- [ ] Health check endpoints for critical dependencies
- [ ] Metrics for key business and operational indicators
- [ ] Sensitive data redacted from all log output (no tokens, PII, payloads)

### Done When

- Key operations produce structured log entries with context
- No sensitive data appears in logs
- Health checks verify critical dependencies

---

## Phase 8: Make it Tested

**Goal**: Comprehensive test coverage for the feature. Tests should verify
behavior, not implementation details.

**Time budget**: ~10% of total task time.

### Checklist

- [ ] Happy path covered with end-to-end tests
- [ ] Edge cases from Phase 3 have dedicated tests
- [ ] Error conditions tested (correct error types, messages)
- [ ] Boundary values tested (zero, one, max, overflow)
- [ ] Security cases tested (malicious input, permission boundaries)
- [ ] Integration tests for critical external interactions
- [ ] Performance tests for critical paths (if Phase 6 applied)

### Test Structure

Follow Arrange-Act-Assert for every test:

1. **Arrange**: Set up test data and preconditions
1. **Act**: Perform the operation being tested
1. **Assert**: Verify the expected outcome

### What NOT to Do

- Don't test framework or library internals
- Don't write tests that depend on execution order
- Don't test implementation details (test behavior)
- Don't leave flaky tests — fix or remove them

### Done When

- All happy paths have passing tests
- Edge cases and error conditions are tested
- Tests are deterministic and independent
- No test depends on another test's side effects

---

## Phase 9: Make it Documented

**Goal**: Document what users and future developers need to know. Don't
over-document — code should be mostly self-explanatory from Phase 2.

**Time budget**: ~5% of total task time.

### Checklist

- [ ] Public API documented (parameters, return values, examples)
- [ ] Non-obvious design decisions explained ("why", not "what")
- [ ] README or user-facing docs updated if behavior changed
- [ ] Configuration options documented with defaults
- [ ] Breaking changes documented with migration instructions

### What NOT to Do

- Don't document obvious code ("increment counter by 1")
- Don't add docstrings to every private function
- Don't write documentation that duplicates the code
- Don't leave TODOs in documentation — either do it or create a ticket

### Done When

- A new developer can use the feature from documentation alone
- Design decisions are explained where non-obvious
- No stale documentation references old behavior

---

## Phase 10: Review Tech Debt (when applicable)

**Goal**: Revisit shortcuts from earlier phases. Document what should be improved
later, fix high-value items now. Skip for small bug fixes or trivial changes.

**Time budget**: ~5% of total task time (when applicable).

### Checklist

- [ ] Review hardcoded values from Phase 1 — document or replace
- [ ] Review copy-pasted logic — extract if used 3+ times
- [ ] Apply new patterns to related code (not the entire codebase)
- [ ] Create follow-up tickets for deferred improvements
- [ ] All tests still pass after changes

### Scope Control

- Focus on files touched in the current task — don't refactor unrelated code
- Box time to 20% of the original task at most

### Done When

- Shortcuts are documented or resolved
- Follow-up tickets exist for deferred work
- All tests pass
