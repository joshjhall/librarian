---
description: Shell scripting conventions, naming patterns, and testing guidance. Use when writing or editing shell scripts, bash functions, or shell tests.
---

# Shell Scripting

## Naming Conventions

- **Library files** are nouns: `validation.sh`, `error_handling.sh`, `lock_management.sh`
- **Functions** are verbs: `validate_email()`, `cleanup_temp_files()`, `sanitize_filename()`
- **Pattern**: `verb_object` for functions, `domain_purpose.sh` for files

## Namespace Safety

Bash has no native namespacing. Prevent collisions:

| Category           | Pattern               | Example                   |
| ------------------ | --------------------- | ------------------------- |
| Internal variables | `{lib}_{purpose}`     | `arith_calc_result`       |
| Constants          | `{LIB}_{CONSTANT}`    | `LOCK_MAX_TIMEOUT`        |
| Public functions   | `verb_object`         | `validate_email()`        |
| Private functions  | `_lib_verb_object`    | `_arith_check_overflow()` |
| Temporary vars     | `tmp_{lib}_{purpose}` | `tmp_arith_overflow`      |

- Always declare `local` variables inside functions
- Never shadow system variables (`PATH`, `HOME`, `USER`)

## Error Handling

- Use proper exit codes (0 success, 1 general error, 2 usage error)
- Provide clear, actionable error messages with context
- Detect environment (test/CI/production) and adjust behavior
- Clean up temporary resources on exit (use `trap`)
- Never suppress all errors — log and handle appropriately

## Error Messages

- Be specific about what went wrong and include relevant values
- Always suggest next steps or fixes
- Simple messages by default, full details with `--debug` or verbose flags
- Frame issues as problems to solve, not user mistakes

```bash
# Bad — no context, no fix
echo "Error: failed" >&2; exit 1

# Good — what failed, relevant value, how to fix
echo "Error: config file not found: ${config_path}" >&2
echo "  Create it with: cp config.example.sh ${config_path}" >&2
exit 1
```

## Testing (Arrange-Act-Assert)

```bash
test_function_basic_usage() {
    # Arrange
    local input="test data"
    local expected="expected result"

    # Act
    local actual
    actual=$(function_to_test "$input")

    # Assert
    assert_equals "$expected" "$actual" "Should process input correctly"
}
```

- Each test is independent — no shared mutable state
- Test edge cases: empty strings, special characters, boundary values
- Always quote variables in assertions: `assert_equals "$expected" "$actual"`
- Verify both return values and side effects (files created, env vars set)

## Script Editing Safety

- Review shell scripts with full context awareness before modifying
- Verify syntax with `bash -n` after changes
- Make incremental changes — one logical edit at a time
- Prefer creating new files or wrapper scripts over complex in-place edits
- Shell quoting rules are fragile: test thoroughly after any modification
