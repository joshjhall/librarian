---
description: Phased feature development and task decomposition guidance. Use when implementing new features, planning multi-step tasks, or decomposing complex work.
---

# Development Workflow

**Detailed reference**: See `phase-details.md` in this skill directory for
checklists, common mistakes, and "done" criteria per phase. Load it when
starting a new task or transitioning between phases.

## Phased Approach

Build features in focused passes rather than trying to do everything at once.

### Phase 1: Make it Work

- Get real end-to-end functionality running on the happy path
- No stubs or TODOs — actual working code with real operations
- Use hardcoded values or copy-paste if needed (clean up later)
- One simple test proving core behavior works

### Phase 2: Make it Right

- Refactor for clarity: better names, smaller functions, reduced nesting
- Extract duplicated logic (3+ instances threshold)
- Apply project conventions and design patterns
- Add proper types and interfaces
- Verify Phase 1 tests still pass

### Phase 3: Make it Safe

- Validate all inputs at system boundaries
- Handle null/empty/negative/oversized values
- Add error handling and resource cleanup
- Consider unicode, encoding, and concurrency edge cases

### Phase 4: Make it Secure

- Validate against allowlists, not denylists
- Use parameterized queries and context-appropriate output encoding
- Never expose internal error details to users
- Mask sensitive data in logs
- Add audit logging for sensitive operations

### Phase 5: Make it Compliant (when applicable)

- Identify which regulations apply (GDPR, HIPAA, SOC2, PCI-DSS, etc.)
- Add required data handling: consent, retention, right-to-delete
- Ensure PII is encrypted at rest and in transit
- Add audit trails for regulated operations
- Verify third-party dependencies meet compliance requirements

### Phase 6: Make it Fast (only when needed)

- Profile before optimizing — identify actual bottlenecks
- Fix N+1 queries, unnecessary allocations, missing indexes
- Add caching with clear invalidation rules
- Batch I/O operations where possible

### Phase 7: Make it Observable (when applicable)

- Add structured logging with consistent severity levels
- Include correlation IDs for request tracing across services
- Expose health check endpoints for critical dependencies
- Add metrics for key business and operational indicators
- Keep observability modular — easy to disable in simple projects

### Phase 8: Make it Tested

- Cover happy path, edge cases, error conditions, boundary values
- Follow existing project test patterns and conventions
- Mock external dependencies at boundaries
- Add performance tests for critical paths

### Phase 9: Make it Documented

- Document public APIs and non-obvious design decisions
- Keep code comments focused on "why", not "what"

### Phase 10: Review Tech Debt (when applicable)

- Revisit shortcuts taken in earlier phases — document or fix them
- Flag hardcoded values, copy-pasted logic, or missing abstractions
- Create follow-up tickets for deferred work
- Assess whether any earlier phase needs a second pass

## Key Principles

- **One goal per phase** — don't mix refactoring with feature work
- **Later phases can fix earlier work** — if security review reveals a
  Phase 1 design flaw, fix it
- **Skip phases that don't apply** — a pure refactoring task skips most phases;
  a bug fix may only need phases 1, 3, and 8; phases 5, 7, and 10 are optional
  depending on project complexity

## When to Use

- New feature development
- API endpoint creation
- Component or module implementation

## When NOT to Use

- Quick bug fixes (just fix it)
- Pure documentation tasks
- Emergency hotfixes
- Spikes or research

## Task Decomposition

When a task feels too large, break it down:

- **By slice**: Deliver thin vertical slices (Create/Read first, Update/Delete later)
- **By risk**: Low-risk changes first, high-risk changes separately
- **By dependency**: Independent work first, dependent work after

### Scope Control

- If the task list grows beyond 10 items, split into "do now" vs "do later"
- "While I'm at it..." is a scope creep warning sign — capture the idea, defer it
- Each subtask should be independently valuable
