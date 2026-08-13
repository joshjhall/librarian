---
description: Deterministic code health pre-scan for tech debt markers, debug statements, empty error handlers, and unused imports. Runs patterns.sh before LLM analysis. Used by the checker agent.
---

# check-code-health

Deterministic code health pattern detection. The `patterns.sh` pre-scan
catches regex-matchable code health findings before LLM analysis, reducing
token usage for patterns that code can detect better than a language model.

**Companion files**: See `contract.md` for the output format. See
`thresholds.yml` for configurable severity levels.

## Pre-Scan Categories

`patterns.sh` detects these code health patterns:

| Category           | What it detects                                        |
| ------------------ | ------------------------------------------------------ |
| `tech-debt-marker` | TODO, FIXME, HACK, XXX, WORKAROUND comments            |
| `debug-statement`  | console.log, print(), debugger, binding.pry (non-test) |
| `empty-handler`    | Empty catch/except/rescue blocks, swallowed Go errors  |

## Pass 2 — LLM Analysis

After the pre-scan, analyze files the pre-scan missed for:

- **File length**: Production code line counting with language-aware exclusions
  (test blocks, comments, docstrings)
- **Function complexity**: Cyclomatic complexity estimation from branching
  constructs
- **Code duplication**: Blocks of 10+ identical lines across files
- **Dead code**: Unreachable code after return/throw/exit, unused functions
- **Naming drift**: Inconsistent naming conventions within the same module
- **Deprecated API**: Usage of deprecated functions with known replacements

## Exclusions

The pre-scan automatically skips:

- Non-source files (markdown, JSON, YAML, TOML, config, lock files)
- Test files for the `debug-statement` category (debug output in tests is
  expected)
- Files a project declares under `stdout_is_output` in `.claude/pre-review.yml`
  — for a CLI, `print()`/`console.log` **is** the program's output, not a debug
  leftover (#686):

  ```yaml
  stdout_is_output:
    - src/cli.py
    - bin/*.js
  ```

  Values are gitignore-style patterns, matched relative to the repo root. The
  exemption covers the **print family only**: a declared file's `breakpoint()`,
  `debugger`, `binding.pry` and friends still fire, because none of those is
  ever a program's output. With no config, or none of this key, behaviour is
  unchanged.
