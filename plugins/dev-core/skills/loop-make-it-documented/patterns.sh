#!/usr/bin/env bash
# loop-make-it-documented — Deterministic Pre-Scan
#
# Detects documentation gaps: public functions without docstrings, exported
# symbols without JSDoc/GoDoc, public classes without documentation.
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

    # Skip test files and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml | *.lock) continue ;;
    esac

    basename=$(/usr/bin/basename "$file")
    ext="${basename##*.}"

    case "$ext" in
        py)
            # --- Python: public functions without docstrings ---
            /usr/bin/awk '
                /^def [a-zA-Z][a-zA-Z0-9_]*\(/ {
                    func_line = NR
                    func_text = $0
                    # Check if next non-blank line is a docstring
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "%s\t%d\tundocumented-public-function\tNo docstring: %.60s\tHIGH\n",
                            FILENAME, func_line, func_text
                    }
                }
                /^class [A-Z][a-zA-Z0-9_]*/ {
                    class_line = NR
                    class_text = $0
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "%s\t%d\tundocumented-public-class\tNo docstring: %.60s\tHIGH\n",
                            FILENAME, class_line, class_text
                    }
                }
            ' "$file" 2>/dev/null || true
            ;;
        ts | js | tsx | jsx)
            # --- TypeScript/JavaScript: exported functions without JSDoc ---
            /usr/bin/grep -n '^export\s\+\(async\s\+\)\?function\s\+\w\+\|^export\s\+\(default\s\+\)\?class\s\+\w\+' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check if preceded by JSDoc comment (/** ... */)
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(/usr/bin/sed -n "${prev_line}p" "$file")
                        if ! /usr/bin/printf '%s' "$prev_content" | /usr/bin/grep -qE '^\s*\*/' 2>/dev/null; then
                            evidence=$(/usr/bin/printf '%.60s' "$content")
                            category="undocumented-export"
                            if /usr/bin/printf '%s' "$content" | /usr/bin/grep -q 'class' 2>/dev/null; then
                                category="undocumented-public-class"
                            fi
                            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "$category" \
                                "No JSDoc: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        go)
            # --- Go: exported functions without GoDoc comments ---
            /usr/bin/grep -n '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(/usr/bin/sed -n "${prev_line}p" "$file")
                        if ! /usr/bin/printf '%s' "$prev_content" | /usr/bin/grep -qE "^// ${func_name}" 2>/dev/null; then
                            evidence=$(/usr/bin/printf '%.60s' "$content")
                            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-export" \
                                "No GoDoc for ${func_name}: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        sh | bash)
            # --- Shell: functions without usage comment ---
            /usr/bin/grep -n '^\w\+()' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(/usr/bin/sed -n "${prev_line}p" "$file")
                        if ! /usr/bin/printf '%s' "$prev_content" | /usr/bin/grep -qE '^\s*#' 2>/dev/null; then
                            evidence=$(/usr/bin/printf '%.60s' "$content")
                            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-function" \
                                "No comment before function: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
