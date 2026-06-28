---
description: Documentation standards, progressive writing, and organization patterns. Use when writing documentation, docstrings, READMEs, or reviewing existing docs.
---

# Documentation Authoring

## Core Principles

- Documentation is progressive — write incrementally with code, not as an afterthought
- Be concrete: real commands, real paths, real code examples (not pseudocode)
- Test every example — copy-paste and run before publishing
- One topic per file, one canonical location — cross-reference, don't duplicate

## Writing Standards

- Lead with value: most important information first
- Keep comments focused on "why", not "what" the code does
- Replace vague pronouns ("it", "this") with specific terms
- Include at least one working example and one "what if" error case
- Add output examples when the result isn't obvious

```text
Bad:  "It processes the data and returns the result to the caller."
Good: "parse_config() reads the YAML file at config_path and returns
       a validated Settings object, raising ConfigError on invalid keys."
```

## Structure

### File Documentation (README, guides)

1. Overview — what it does, why it exists
1. Quick Start — minimal steps to get running
1. Configuration — options and defaults
1. Examples — real-world usage
1. Troubleshooting — common issues and fixes

### Code Documentation (docstrings, comments)

- Public API: document parameters, return values, exceptions, and examples
- Internal code: comment only non-obvious decisions and "why" reasoning
- Complex logic: brief inline comment explaining the approach

## Progressive Documentation by Phase

Match documentation depth to development maturity:

- **Phase 1 (Make it Work)**: Self-documenting names, minimal inline comments
- **Phase 2 (Make it Right)**: Parameter types, design decision notes
- **Phase 3 (Make it Safe)**: Error conditions, edge case documentation
- **Phase 4 (Make it Secure)**: Security considerations, input validation notes
- **Phase 8 (Make it Documented)**: Complete docstrings, external docs, ADRs

## Organization

- **Logical over temporal**: Group by purpose, not by date or author
- **Shallow over deep**: Maximum 2 levels from documentation root
- **Discoverable over hidden**: Index files, descriptive names, consistent conventions
- Cross-reference related concepts rather than duplicating content

## Review Checklist

- Clear title and opening context
- At least one working, tested example
- "When to use" has concrete scenarios
- Common issues documented with solutions
- File paths verified as correct
- No stale examples or broken references
