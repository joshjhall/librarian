#!/usr/bin/env bash
# check-docs-missing-api — Deterministic Pre-Scan
#
# Detects exported/public functions without documentation across languages.
# Uses language-specific patterns to find function definitions missing
# preceding docstring/comment blocks.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# check_prev_lines FILE LINE_NUM PATTERN — returns 0 if PATTERN found in
# the 3 lines before LINE_NUM
check_prev_lines() {
    local file="$1" target_line="$2" pattern="$3"
    local start=$((target_line - 3))
    [ "$start" -lt 1 ] && start=1
    /usr/bin/sed -n "${start},$((target_line - 1))p" "$file" 2>/dev/null |
        /usr/bin/grep -qE "$pattern"
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    case "$file" in
        # --- Python ---
        *.py)
            # Find module-level function/class definitions
            /usr/bin/grep -nE '^(def |class )[A-Za-z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Skip private functions (leading underscore)
                    case "$content" in
                        *"def _"* | *"class _"*) continue ;;
                    esac
                    # Check for docstring (triple quotes) in preceding lines
                    if ! check_prev_lines "$file" "$line_num" '"""'; then
                        # Also check if function body starts with docstring
                        next_lines=$(/usr/bin/sed -n "$((line_num + 1)),$((line_num + 2))p" "$file" 2>/dev/null)
                        if ! /usr/bin/echo "$next_lines" | /usr/bin/grep -qE '^\s+"""'; then
                            evidence=$(/usr/bin/printf '%.80s' "$content")
                            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-api" \
                                "Python: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;

        # --- JavaScript/TypeScript ---
        *.js | *.ts | *.jsx | *.tsx)
            # Find exported functions, classes, types
            /usr/bin/grep -nE '^export (function|class|const|type|interface|enum) ' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check for JSDoc comment (/**) in preceding lines
                    if ! check_prev_lines "$file" "$line_num" '/\*\*'; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "JS/TS: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Go ---
        *.go)
            # Find exported functions (capitalized, not in test files)
            case "$file" in *_test.go) continue ;; esac
            /usr/bin/grep -nE '^func [A-Z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Go convention: comment line immediately before with function name
                    func_name=$(/usr/bin/echo "$content" | /usr/bin/grep -oE 'func [A-Z][A-Za-z0-9]*' | /usr/bin/awk '{print $2}')
                    if [ -n "$func_name" ]; then
                        prev_line=$(/usr/bin/sed -n "$((line_num - 1))p" "$file" 2>/dev/null)
                        if ! /usr/bin/echo "$prev_line" | /usr/bin/grep -q "// ${func_name}"; then
                            evidence=$(/usr/bin/printf '%.80s' "$content")
                            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-api" \
                                "Go: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;

        # --- Rust ---
        *.rs)
            # Find pub fn and pub struct
            /usr/bin/grep -nE '^pub (fn|struct|enum|trait|type) ' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check for /// doc comment
                    if ! check_prev_lines "$file" "$line_num" '^\s*///'; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Rust: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Shell ---
        *.sh | *.bash)
            # Find function definitions
            /usr/bin/grep -nE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)|^function [a-zA-Z_]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Skip private functions (leading underscore)
                    case "$content" in
                        _* | *"function _"*) continue ;;
                    esac
                    # Check for # comment on preceding line
                    if ! check_prev_lines "$file" "$line_num" '^\s*#'; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Shell: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Ruby ---
        *.rb)
            /usr/bin/grep -nE '^\s*def [a-z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    if ! check_prev_lines "$file" "$line_num" '^\s*#'; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Ruby: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Java/Kotlin ---
        *.java | *.kt)
            /usr/bin/grep -nE '^\s*public .*(void|int|String|boolean|List|Map|Optional|fun )' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    if ! check_prev_lines "$file" "$line_num" '/\*\*'; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Java/Kotlin: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
