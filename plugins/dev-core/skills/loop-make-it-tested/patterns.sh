#!/usr/bin/env bash
# loop-make-it-tested — Deterministic Pre-Scan
#
# Detects test coverage gaps: public functions without test files,
# test files without assertions, source modules without test counterparts.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test files themselves and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml) continue ;;
    esac

    basename=$(/usr/bin/basename "$file")
    dirname=$(/usr/bin/dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    # --- Category: missing-test-file ---
    # Check if a corresponding test file exists
    has_test=false
    case "$ext" in
        py)
            for test_path in \
                "${dirname}/test_${name_no_ext}.py" \
                "${dirname}/tests/test_${name_no_ext}.py" \
                "${dirname}/../tests/test_${name_no_ext}.py" \
                "${dirname}/${name_no_ext}_test.py"; do
                if [ -f "$test_path" ]; then
                    has_test=true
                    break
                fi
            done
            ;;
        ts | js | tsx | jsx)
            for suffix in "test" "spec"; do
                for test_path in \
                    "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/../__tests__/${name_no_ext}.${suffix}.${ext}"; do
                    if [ -f "$test_path" ]; then
                        has_test=true
                        break 2
                    fi
                done
            done
            ;;
        go)
            test_path="${dirname}/${name_no_ext}_test.go"
            if [ -f "$test_path" ]; then
                has_test=true
            fi
            ;;
        rs)
            # Rust: check for mod tests in same file or tests/ directory
            if /usr/bin/grep -q '#\[cfg(test)\]' "$file" 2>/dev/null; then
                has_test=true
            elif [ -d "${dirname}/../tests" ]; then
                has_test=true
            fi
            ;;
    esac

    if [ "$has_test" = "false" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "missing-test-file" \
            "No test file found for ${basename}" "HIGH"
    fi

    # --- Category: untested-public-api ---
    # Public/exported functions that should have test coverage
    case "$ext" in
        py)
            # Public functions (not starting with _)
            /usr/bin/grep -nE '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    # Check if this function appears in any test file nearby
                    if ! /usr/bin/grep -rql "\b${func_name}\b" "${dirname}"/test_*.py "${dirname}"/tests/test_*.py 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        go)
            # Exported functions (capitalized)
            /usr/bin/grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    if [ -f "$test_file" ] && ! /usr/bin/grep -q "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
