#!/usr/bin/env bash
# loop-make-it-right — Deterministic Pre-Scan
#
# Detects structural quality issues: long functions, deep nesting, and
# single-character variable names outside loop counters.
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

# Configurable via environment (thresholds.yml values passed by orchestrator)
MAX_FUNCTION_LINES="${LOOP_MAX_FUNCTION_LINES:-50}"
MAX_NESTING_DEPTH="${LOOP_MAX_NESTING_DEPTH:-4}"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # --- Category: long-function ---
    # Detect function definitions and count lines until closing
    case "$file" in
        *.py)
            # Python: count lines from def to next def/class or dedent
            /usr/bin/grep -n '^\s*def \w\+' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Count lines until next function/class at same or lower indent
                    indent=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/[^ ].*//' | /usr/bin/wc -c)
                    end_line=$(/usr/bin/sed -n "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -n "^.\{0,${indent}\}[^ ]" |
                        /usr/bin/head -1 | /usr/bin/cut -d: -f1)
                    if [ -n "$end_line" ]; then
                        func_lines=$((end_line))
                    else
                        total=$(/usr/bin/wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx | *.go | *.rs)
            # Brace-delimited languages: count from opening { to closing }
            /usr/bin/grep -nE '^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+' "$file" 2>/dev/null |
                while IFS=: read -r line_num _content; do
                    # Simple heuristic: count lines from definition to next function
                    next_func=$(/usr/bin/sed -n "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -nE '^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+' |
                        /usr/bin/head -1 | /usr/bin/cut -d: -f1)
                    if [ -n "$next_func" ]; then
                        func_lines=$((next_func))
                    else
                        total=$(/usr/bin/wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(/usr/bin/printf '%.60s' "$_content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

    # --- Category: deep-nesting ---
    # Count leading whitespace to detect excessive nesting
    case "$file" in
        *.py)
            # Python: 4-space indent, nesting = indent / 4
            /usr/bin/awk -v max="$MAX_NESTING_DEPTH" '
                /^[[:space:]]+[^[:space:]]/ {
                    match($0, /^[[:space:]]+/)
                    depth = int(RLENGTH / 4)
                    if (depth > max) {
                        printf "%s\t%d\tdeep-nesting\tNesting depth %d (max %d): %.60s\tHIGH\n",
                            FILENAME, NR, depth, max, $0
                    }
                }
            ' "$file" 2>/dev/null || true
            ;;
        *.ts | *.js | *.tsx | *.jsx | *.go | *.rs)
            # Brace languages: 2-space indent, nesting = indent / 2
            /usr/bin/awk -v max="$MAX_NESTING_DEPTH" '
                /^[[:space:]]+[^[:space:]]/ {
                    match($0, /^[[:space:]]+/)
                    depth = int(RLENGTH / 2)
                    if (depth > max) {
                        printf "%s\t%d\tdeep-nesting\tNesting depth %d (max %d): %.60s\tHIGH\n",
                            FILENAME, NR, depth, max, $0
                    }
                }
            ' "$file" 2>/dev/null || true
            ;;
    esac

    # --- Category: single-char-name ---
    # Single-character variable names outside common loop patterns
    case "$file" in
        *.py)
            /usr/bin/grep -nE '^\s+[a-zA-Z]\s*=' "$file" 2>/dev/null |
                /usr/bin/grep -vE '^\s*(for|with)\s+[a-zA-Z]\s+in\b|_\s*=' |
                while IFS=: read -r line_num content; do
                    # Extract the variable name
                    varname=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^[[:space:]]*\([a-zA-Z]\)[[:space:]]*=.*/\1/')
                    # Skip common loop vars and conventional single-char names
                    case "$varname" in
                        i | j | k | n | x | y | _ | e | f) continue ;;
                    esac
                    evidence=$(/usr/bin/printf '%.60s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "single-char-name" \
                        "Single-character variable '${varname}': ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
