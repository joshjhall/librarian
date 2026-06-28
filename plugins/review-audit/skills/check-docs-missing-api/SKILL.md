---
description: Detects undocumented public APIs and complex functions across languages. Uses language-specific regex for exported symbols without docstrings. Used by checker agent.
---

# check-docs-missing-api

Analyze source files for public APIs and functions that lack documentation.
You receive pre-scan results (deterministic hits from `patterns.sh`) and
file contents from the checker agent.

**Companion files**: See `contract.md` for output format. See `thresholds.yml`
for configurable thresholds — load both when running analysis.

## Workflow

1. Review pre-scan results passed by the checker agent. For each:

   - Read the function/class definition and its context
   - **Confirm**: the API is genuinely public and complex enough to warrant
     documentation
   - **Dismiss**: the function is simple enough to be self-documenting (e.g.,
     trivial getters, one-line utilities)

1. Analyze files for additional undocumented APIs the pre-scan missed:

   - Complex functions with multiple parameters or return values
   - Public class methods with non-obvious behavior
   - Exported constants or configuration that need explanation

1. Emit findings following `contract.md` format

## Categories

### undocumented-public-api

Exported functions, classes, or API endpoints without documentation:

- Exported functions without docstrings/JSDoc/javadoc
- REST endpoints without route-level descriptions
- Public class methods without parameter/return documentation
- Public module-level constants without explanatory comments

Severity: **medium** (complex public API), **low** (simple public API)

Evidence: function signature, why documentation would help

### undocumented-complex-function

Internal functions that are complex enough to need documentation:

- Functions with 4+ parameters
- Functions with complex control flow (multiple branches, loops)
- Functions with non-obvious side effects
- Functions whose name doesn't fully explain their behavior

Severity: **medium** (frequently called, complex logic),
**low** (internal utility, used in few places)

Evidence: function signature, complexity indicators, call sites

## Language-Specific Detection

The pre-scan (`patterns.sh`) uses these language-specific patterns:

| Language    | Public API Pattern                      | Docstring Pattern               |
| ----------- | --------------------------------------- | ------------------------------- |
| Python      | `def` or `class` at module level        | `"""` within 2 lines above      |
| JS/TS       | `export (function\|class\|const\|type)` | `/**` within 2 lines above      |
| Go          | `func [A-Z]`                            | `// FuncName` on preceding line |
| Rust        | `pub fn` or `pub struct`                | `///` on preceding line(s)      |
| Shell       | function definition or `name()`         | `#` comment on preceding line   |
| Ruby        | `def` in class context                  | `#` comment on preceding line   |
| Java/Kotlin | `public` methods                        | `/**` within 2 lines above      |

## Guidelines

- Focus on complex or non-obvious APIs — simple getters/setters can be
  undocumented
- Do not flag test files, generated code, or vendor/third-party code
- Do not flag functions in early-stage/prototype code
- Consider the function's call frequency — heavily used functions need docs more
- Accept that some internal utilities are self-documenting by name
- If no issues found, return zero findings

## When to Use

- Loaded by the checker agent during source-file analysis
- Applies to: source files (`.py`, `.js`, `.ts`, `.go`, `.rs`, `.rb`,
  `.java`, `.kt`, `.sh`)

## When NOT to Use

- Not invoked directly — always via the checker agent
- Not for documentation accuracy (use check-docs-staleness)
- Not for code examples (use check-docs-examples)
