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

## Portability & Runtime Selection

Scripts must run on **base macOS**, whose stock `/bin/bash` is **3.2** (2007).
Keep every `*.sh` **bash-3.2 clean** — these bash-4+ constructs are banned and
gated by `tests/lint-shell-portability.sh`:

| Banned (bash 4+)                       | Portable replacement (bash 3.2)                          |
| -------------------------------------- | -------------------------------------------------------- |
| `declare -A` / `local -A` (assoc maps) | space-delimited string set + `case " $set " in *" x "*)` |
| `mapfile` / `readarray`                | `while IFS= read -r line; do …; done < file`             |
| `declare -n` / `local -n` (namerefs)   | pass values / use a flat `"key<TAB>val"` string map      |
| `${v,,}` / `${v^^}` (case conversion)  | `tr '[:upper:]' '[:lower:]'` (and vice-versa)            |
| `;;&` (case fallthrough)               | duplicate the arm, or restructure the `case`             |

For a worked flat-map + string-set example, see
`plugins/workflow/scripts/golem-gate-watch.sh`.

**Runtime selection for code tools.** A pre-scan tool's primary implementation is
Python **3.11+** (`patterns.py`); the same-dir `patterns.sh` is a thin selector
that exec's it when a `python3>=3.11` is present and otherwise runs its own bash
body as the fallback. Both emit the identical TSV contract
(`file<TAB>line<TAB>category<TAB>evidence<TAB>certainty`); parity is pinned by
`tests/validate-python-ports.sh`. The selector preamble:

```bash
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi
# bash fallback below…
```

**Fail loud when a required runtime is absent** — never silent-empty. When a
script genuinely requires a newer bash, gate it up front:

```bash
if [ "${BASH_VERSION%%.*}" -lt 4 ]; then
    echo "Error: this script requires Bash 4+ (found ${BASH_VERSION})" >&2
    echo "  On macOS: brew install bash, then run under the newer bash." >&2
    exit 1
fi
```
